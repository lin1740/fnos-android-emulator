/*
 * See decode_h264.h. Ported from ../tier6-vaapi-decode/main.c (a one-shot,
 * single-frame CLI spike) into a persistent-state, repeated-call API this
 * daemon can drive per request - the same restructuring encode_one_frame()/
 * vaapi_state_ensure_resolution() already did for the encode side. The
 * actual H.264 parsing and VA-API/Vulkan mechanics are unchanged from the
 * spike; see tier6-vaapi-decode/README.md for the full bug-by-bug trail
 * that produced them (bit-exact against software decode, confirmed via
 * PSNR). This file's own comments focus on what's new here: turning a
 * "parse one file, decode one frame, exit" program into "keep VA-API/
 * Vulkan open across calls, decode whatever buffer is handed to it".
 */

#include "decode_h264.h"

#include <dlfcn.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define VK_NO_PROTOTYPES
#include <vulkan/vulkan.h>

#include <va/va.h>
#include <va/va_drm.h>
#include <va/va_drmcommon.h>
#include <va/va_vpp.h>

#define DRM_DEVICE "/dev/dri/renderD128"

#define CHECK_VA(status, msg)                                                \
    do {                                                                     \
        if ((status) != VA_STATUS_SUCCESS) {                                 \
            fprintf(stderr, "decode: %s failed: %s (0x%x)\n", (msg),         \
                    vaErrorStr(status), (status));                           \
            return -1;                                                      \
        }                                                                    \
    } while (0)

static unsigned int align16(unsigned int v) { return (v + 15) & ~15u; }

/* ------------------------------------------------------------------ *
 * NAL extraction / RBSP de-escaping / Exp-Golomb bitreader / SPS-PPS-
 * slice-header parsing: byte-for-byte the same as tier6-vaapi-decode/
 * main.c - see that file's own comments for the full spec-reference
 * detail. Kept terse here.
 * ------------------------------------------------------------------ */
typedef struct {
    const uint8_t *data;
    size_t size;
    int nal_ref_idc;
    int nal_unit_type;
} NalUnit;

static int find_next_start_code(const uint8_t *buf, size_t size, size_t from) {
    for (size_t i = from; i + 2 < size; i++)
        if (buf[i] == 0 && buf[i + 1] == 0 && buf[i + 2] == 1) return (int)i;
    return -1;
}

static int extract_nals(const uint8_t *buf, size_t size, NalUnit *out, int max_nals) {
    int count = 0;
    int sc = find_next_start_code(buf, size, 0);
    while (sc >= 0 && count < max_nals) {
        size_t nal_start = sc + 3;
        int next_sc = find_next_start_code(buf, size, nal_start);
        size_t nal_end = (next_sc >= 0) ? (size_t)next_sc : size;
        while (nal_end > nal_start && buf[nal_end - 1] == 0) nal_end--;
        if (nal_end > nal_start) {
            out[count].nal_ref_idc = (buf[nal_start] >> 5) & 0x3;
            out[count].nal_unit_type = buf[nal_start] & 0x1f;
            out[count].data = buf + nal_start + 1;
            out[count].size = nal_end - nal_start - 1;
            count++;
        }
        sc = next_sc;
    }
    return count;
}

static uint8_t *deescape_rbsp(const uint8_t *data, size_t size, size_t *out_size) {
    uint8_t *out = malloc(size);
    size_t o = 0;
    int zero_run = 0;
    for (size_t i = 0; i < size; i++) {
        if (zero_run >= 2 && data[i] == 0x03) { zero_run = 0; continue; }
        out[o++] = data[i];
        zero_run = (data[i] == 0) ? zero_run + 1 : 0;
    }
    *out_size = o;
    return out;
}

typedef struct {
    const uint8_t *buf;
    size_t size;
    size_t bit_pos;
} BitReader;

static unsigned int br_bit(BitReader *br) {
    size_t byte = br->bit_pos / 8;
    int shift = 7 - (int)(br->bit_pos % 8);
    unsigned int bit = (byte < br->size) ? ((br->buf[byte] >> shift) & 1) : 0;
    br->bit_pos++;
    return bit;
}

static unsigned int br_bits(BitReader *br, int n) {
    unsigned int v = 0;
    for (int i = 0; i < n; i++) v = (v << 1) | br_bit(br);
    return v;
}

static unsigned int br_ue(BitReader *br) {
    int leading_zeros = 0;
    while (br_bit(br) == 0 && leading_zeros < 32) leading_zeros++;
    if (leading_zeros == 0) return 0;
    unsigned int suffix = br_bits(br, leading_zeros);
    return (1u << leading_zeros) - 1 + suffix;
}

static int br_se(BitReader *br) {
    unsigned int code = br_ue(br);
    int sign = (code & 1) ? 1 : -1;
    return sign * (int)((code + 1) / 2);
}

typedef struct {
    int profile_idc;
    int seq_parameter_set_id;
    int log2_max_frame_num_minus4;
    int pic_order_cnt_type;
    int log2_max_pic_order_cnt_lsb_minus4;
    int max_num_ref_frames;
    int pic_width_in_mbs_minus1;
    int pic_height_in_map_units_minus1;
    int frame_mbs_only_flag;
} SpsInfo;

typedef struct {
    int pic_parameter_set_id;
    int seq_parameter_set_id;
    int entropy_coding_mode_flag;
    int pic_order_present_flag;
    int num_ref_idx_l0_active_minus1;
    int num_ref_idx_l1_active_minus1;
    int weighted_pred_flag;
    int weighted_bipred_idc;
    int pic_init_qp_minus26;
    int chroma_qp_index_offset;
    int deblocking_filter_control_present_flag;
    int redundant_pic_cnt_present_flag;
} PpsInfo;

static int parse_sps(const uint8_t *rbsp, size_t size, SpsInfo *sps) {
    BitReader br = { rbsp, size, 0 };
    sps->profile_idc = br_bits(&br, 8);
    br_bits(&br, 8);
    br_bits(&br, 8);
    sps->seq_parameter_set_id = br_ue(&br);
    sps->log2_max_frame_num_minus4 = br_ue(&br);
    sps->pic_order_cnt_type = br_ue(&br);
    if (sps->pic_order_cnt_type == 0) {
        sps->log2_max_pic_order_cnt_lsb_minus4 = br_ue(&br);
    } else if (sps->pic_order_cnt_type == 1) {
        fprintf(stderr, "decode: pic_order_cnt_type 1 not supported\n");
        return -1;
    }
    sps->max_num_ref_frames = br_ue(&br);
    br_bit(&br);
    sps->pic_width_in_mbs_minus1 = br_ue(&br);
    sps->pic_height_in_map_units_minus1 = br_ue(&br);
    sps->frame_mbs_only_flag = br_bit(&br);
    if (!sps->frame_mbs_only_flag) {
        fprintf(stderr, "decode: interlaced SPS not supported\n");
        return -1;
    }
    return 0;
}

static int parse_pps(const uint8_t *rbsp, size_t size, PpsInfo *pps) {
    BitReader br = { rbsp, size, 0 };
    pps->pic_parameter_set_id = br_ue(&br);
    pps->seq_parameter_set_id = br_ue(&br);
    pps->entropy_coding_mode_flag = br_bit(&br);
    pps->pic_order_present_flag = br_bit(&br);
    if (br_ue(&br) != 0) {
        fprintf(stderr, "decode: slice groups not supported\n");
        return -1;
    }
    pps->num_ref_idx_l0_active_minus1 = br_ue(&br);
    pps->num_ref_idx_l1_active_minus1 = br_ue(&br);
    pps->weighted_pred_flag = br_bit(&br);
    pps->weighted_bipred_idc = br_bits(&br, 2);
    pps->pic_init_qp_minus26 = br_se(&br);
    br_se(&br);
    pps->chroma_qp_index_offset = br_se(&br);
    pps->deblocking_filter_control_present_flag = br_bit(&br);
    br_bit(&br);
    pps->redundant_pic_cnt_present_flag = br_bit(&br);
    return 0;
}

typedef struct {
    unsigned int first_mb_in_slice;
    unsigned int slice_type;
    unsigned int frame_num;
    unsigned int pic_order_cnt_lsb;
    int slice_qp_delta;
    unsigned int header_bits;
} SliceHeader;

static int parse_slice_header(const uint8_t *rbsp, size_t size, int nal_unit_type, int nal_ref_idc,
                              const SpsInfo *sps, const PpsInfo *pps, SliceHeader *sh) {
    BitReader br = { rbsp, size, 0 };
    sh->first_mb_in_slice = br_ue(&br);
    sh->slice_type = br_ue(&br);
    br_ue(&br); /* pic_parameter_set_id */
    sh->frame_num = br_bits(&br, sps->log2_max_frame_num_minus4 + 4);
    int is_idr = (nal_unit_type == 5);
    if (is_idr) br_ue(&br); /* idr_pic_id */
    if (sps->pic_order_cnt_type == 0)
        sh->pic_order_cnt_lsb = br_bits(&br, sps->log2_max_pic_order_cnt_lsb_minus4 + 4);
    unsigned int base_type = sh->slice_type % 5;
    if (base_type != 2 && base_type != 4) {
        fprintf(stderr, "decode: non-I slice_type %u not supported\n", sh->slice_type);
        return -1;
    }
    if (nal_ref_idc != 0) {
        if (is_idr) {
            br_bit(&br);
            br_bit(&br);
        } else {
            fprintf(stderr, "decode: non-IDR reference dec_ref_pic_marking not supported\n");
            return -1;
        }
    }
    if (pps->entropy_coding_mode_flag) {
        fprintf(stderr, "decode: CABAC slices not supported\n");
        return -1;
    }
    sh->slice_qp_delta = br_se(&br);
    if (pps->deblocking_filter_control_present_flag) {
        unsigned int disable_idc = br_ue(&br);
        if (disable_idc != 1) {
            br_se(&br);
            br_se(&br);
        }
    }
    sh->header_bits = (unsigned int)br.bit_pos;
    return 0;
}

static unsigned int escaped_bit_offset(const uint8_t *escaped, size_t escaped_size,
                                       unsigned int deescaped_bits) {
    unsigned int seen = 0;
    int zero_run = 0;
    for (size_t i = 0; i < escaped_size && seen < deescaped_bits; i++) {
        if (zero_run >= 2 && escaped[i] == 0x03) { zero_run = 0; continue; }
        unsigned int bits_left = deescaped_bits - seen;
        if (bits_left >= 8) {
            seen += 8;
        } else {
            return (unsigned int)(i * 8 + bits_left);
        }
        zero_run = (escaped[i] == 0) ? zero_run + 1 : 0;
        if (seen >= deescaped_bits) return (unsigned int)((i + 1) * 8);
    }
    return (unsigned int)(escaped_size * 8);
}

/* ------------------------------------------------------------------ *
 * Vulkan de-tiling (see decode_h264.h's own top comment for why this is
 * necessary and why it's dlopen'd): identical to tier6-vaapi-decode's own
 * vk_detile(), except vk_init() only runs once (decode_h264_init()) rather
 * than being called fresh every frame.
 * ------------------------------------------------------------------ */
typedef struct {
    VkInstance instance;
    VkPhysicalDevice phys;
    VkDevice dev;
    VkQueue queue;
    VkCommandPool pool;
    VkCommandBuffer cmd;
    PFN_vkGetInstanceProcAddr GetInstanceProcAddr;
    PFN_vkGetDeviceProcAddr GetDeviceProcAddr;
    PFN_vkCreateImage CreateImage;
    PFN_vkDestroyImage DestroyImage;
    PFN_vkGetImageMemoryRequirements GetImageMemoryRequirements;
    PFN_vkGetImageSubresourceLayout GetImageSubresourceLayout;
    PFN_vkAllocateMemory AllocateMemory;
    PFN_vkFreeMemory FreeMemory;
    PFN_vkBindImageMemory BindImageMemory;
    PFN_vkMapMemory MapMemory;
    PFN_vkUnmapMemory UnmapMemory;
    PFN_vkCreateCommandPool CreateCommandPool;
    PFN_vkAllocateCommandBuffers AllocateCommandBuffers;
    PFN_vkBeginCommandBuffer BeginCommandBuffer;
    PFN_vkEndCommandBuffer EndCommandBuffer;
    PFN_vkCmdPipelineBarrier CmdPipelineBarrier;
    PFN_vkCmdCopyImage CmdCopyImage;
    PFN_vkQueueSubmit QueueSubmit;
    PFN_vkQueueWaitIdle QueueWaitIdle;
    PFN_vkGetDeviceQueue GetDeviceQueue;
    PFN_vkGetPhysicalDeviceMemoryProperties GetPhysicalDeviceMemoryProperties;
    VkPhysicalDeviceMemoryProperties mem_props;
} VkDetiler;

static VkDetiler g_vk;
static int g_vk_ready;

static int vk_check(VkResult r, const char *msg) {
    if (r != VK_SUCCESS) { fprintf(stderr, "decode: %s failed: %d\n", msg, r); return -1; }
    return 0;
}

static int vk_init(void) {
    void *lib = dlopen("libvulkan.so.1", RTLD_NOW | RTLD_LOCAL);
    if (!lib) { fprintf(stderr, "decode: dlopen libvulkan.so.1 failed - decode unavailable\n"); return -1; }
    g_vk.GetInstanceProcAddr = dlsym(lib, "vkGetInstanceProcAddr");
    if (!g_vk.GetInstanceProcAddr) return -1;
#define GET_GLOBAL(name) PFN_vk##name name = (PFN_vk##name)g_vk.GetInstanceProcAddr(NULL, "vk" #name)
#define GET_INST(name) PFN_vk##name name = (PFN_vk##name)g_vk.GetInstanceProcAddr(g_vk.instance, "vk" #name)
    GET_GLOBAL(CreateInstance);
    if (!CreateInstance) return -1;
    VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
                              .pApplicationName = "vaapi-daemon-decode", .apiVersion = VK_API_VERSION_1_1 };
    VkInstanceCreateInfo ii = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
    if (vk_check(CreateInstance(&ii, NULL, &g_vk.instance), "vkCreateInstance")) return -1;

    GET_INST(EnumeratePhysicalDevices);
    GET_INST(GetPhysicalDeviceProperties);
    GET_INST(CreateDevice);
    g_vk.GetDeviceProcAddr = (PFN_vkGetDeviceProcAddr)g_vk.GetInstanceProcAddr(g_vk.instance, "vkGetDeviceProcAddr");
    g_vk.GetPhysicalDeviceMemoryProperties =
        (PFN_vkGetPhysicalDeviceMemoryProperties)g_vk.GetInstanceProcAddr(
            g_vk.instance, "vkGetPhysicalDeviceMemoryProperties");

    VkPhysicalDevice devs[8];
    uint32_t count = 8;
    EnumeratePhysicalDevices(g_vk.instance, &count, devs);
    if (count == 0) return -1;
    VkPhysicalDevice best = VK_NULL_HANDLE;
    for (uint32_t i = 0; i < count; i++) {
        VkPhysicalDeviceProperties p;
        GetPhysicalDeviceProperties(devs[i], &p);
        if (p.deviceType == VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU) { best = devs[i]; break; }
        if (best == VK_NULL_HANDLE) best = devs[i];
    }
    g_vk.phys = best;
    g_vk.GetPhysicalDeviceMemoryProperties(g_vk.phys, &g_vk.mem_props);

    const float prio = 1.0f;
    VkDeviceQueueCreateInfo qi = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                                   .queueFamilyIndex = 0, .queueCount = 1, .pQueuePriorities = &prio };
    const char *exts[] = { "VK_KHR_external_memory_fd", "VK_EXT_external_memory_dma_buf",
                           "VK_EXT_image_drm_format_modifier" };
    VkDeviceCreateInfo di = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
                              .queueCreateInfoCount = 1, .pQueueCreateInfos = &qi,
                              .enabledExtensionCount = 3, .ppEnabledExtensionNames = exts };
    if (vk_check(CreateDevice(g_vk.phys, &di, NULL, &g_vk.dev), "vkCreateDevice")) return -1;

#define GET_DEV(name) g_vk.name = (PFN_vk##name)g_vk.GetDeviceProcAddr(g_vk.dev, "vk" #name)
    GET_DEV(CreateImage); GET_DEV(DestroyImage); GET_DEV(GetImageMemoryRequirements);
    GET_DEV(GetImageSubresourceLayout); GET_DEV(AllocateMemory); GET_DEV(FreeMemory);
    GET_DEV(BindImageMemory); GET_DEV(MapMemory); GET_DEV(UnmapMemory);
    GET_DEV(CreateCommandPool); GET_DEV(AllocateCommandBuffers); GET_DEV(BeginCommandBuffer);
    GET_DEV(EndCommandBuffer); GET_DEV(CmdPipelineBarrier); GET_DEV(CmdCopyImage);
    GET_DEV(QueueSubmit); GET_DEV(QueueWaitIdle); GET_DEV(GetDeviceQueue);
#undef GET_DEV

    g_vk.GetDeviceQueue(g_vk.dev, 0, 0, &g_vk.queue);
    VkCommandPoolCreateInfo pi = { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
                                   .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT };
    if (vk_check(g_vk.CreateCommandPool(g_vk.dev, &pi, NULL, &g_vk.pool), "vkCreateCommandPool")) return -1;
    VkCommandBufferAllocateInfo cai = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
                                        .commandPool = g_vk.pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
                                        .commandBufferCount = 1 };
    if (vk_check(g_vk.AllocateCommandBuffers(g_vk.dev, &cai, &g_vk.cmd), "vkAllocateCommandBuffers")) return -1;
    return 0;
}

static uint32_t vk_find_mem_type(uint32_t bits, VkMemoryPropertyFlags want) {
    for (uint32_t i = 0; i < g_vk.mem_props.memoryTypeCount; i++)
        if ((bits & (1u << i)) && (g_vk.mem_props.memoryTypes[i].propertyFlags & want) == want)
            return i;
    return UINT32_MAX;
}

static int vk_detile(int fd, VkFormat fmt, uint32_t width, uint32_t height, uint64_t modifier,
                     uint64_t real_object_size, uint8_t **out_data, size_t *out_size) {
    VkImageDrmFormatModifierListCreateInfoEXT probe_mod_list = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_LIST_CREATE_INFO_EXT,
        .drmFormatModifierCount = 1, .pDrmFormatModifiers = &modifier,
    };
    VkImageCreateInfo probe_info = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .pNext = &probe_mod_list,
        .imageType = VK_IMAGE_TYPE_2D, .format = fmt, .extent = { width, height, 1 },
        .mipLevels = 1, .arrayLayers = 1, .samples = VK_SAMPLE_COUNT_1_BIT,
        .tiling = VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT,
        .usage = VK_IMAGE_USAGE_TRANSFER_SRC_BIT, .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
        .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
    };
    VkImage probe;
    if (vk_check(g_vk.CreateImage(g_vk.dev, &probe_info, NULL, &probe), "vkCreateImage(probe)")) return -1;
    VkImageSubresource sub = { .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT };
    VkSubresourceLayout real_layout;
    g_vk.GetImageSubresourceLayout(g_vk.dev, probe, &sub, &real_layout);
    g_vk.DestroyImage(g_vk.dev, probe, NULL);

    VkExternalMemoryImageCreateInfo ext_info = {
        .sType = VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO,
        .handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
    };
    VkImageDrmFormatModifierExplicitCreateInfoEXT explicit_mod = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_EXPLICIT_CREATE_INFO_EXT,
        .pNext = &ext_info, .drmFormatModifier = modifier,
        .drmFormatModifierPlaneCount = 1, .pPlaneLayouts = &real_layout,
    };
    VkImageCreateInfo import_info = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .pNext = &explicit_mod,
        .imageType = VK_IMAGE_TYPE_2D, .format = fmt, .extent = { width, height, 1 },
        .mipLevels = 1, .arrayLayers = 1, .samples = VK_SAMPLE_COUNT_1_BIT,
        .tiling = VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT,
        .usage = VK_IMAGE_USAGE_TRANSFER_SRC_BIT, .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
        .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
    };
    VkImage imported;
    if (vk_check(g_vk.CreateImage(g_vk.dev, &import_info, NULL, &imported), "vkCreateImage(import)")) return -1;
    VkMemoryRequirements imp_reqs;
    g_vk.GetImageMemoryRequirements(g_vk.dev, imported, &imp_reqs);
    int fd_dup = dup(fd);
    VkImportMemoryFdInfoKHR import_fd = {
        .sType = VK_STRUCTURE_TYPE_IMPORT_MEMORY_FD_INFO_KHR,
        .handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT, .fd = fd_dup,
    };
    VkMemoryDedicatedAllocateInfo imp_ded = { .sType = VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO,
                                              .pNext = &import_fd, .image = imported };
    VkMemoryAllocateInfo imp_alloc = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                                       .pNext = &imp_ded, .allocationSize = real_object_size,
                                       .memoryTypeIndex = vk_find_mem_type(imp_reqs.memoryTypeBits, 0) };
    VkDeviceMemory imported_mem;
    if (vk_check(g_vk.AllocateMemory(g_vk.dev, &imp_alloc, NULL, &imported_mem), "vkAllocateMemory(import)"))
        return -1;
    if (vk_check(g_vk.BindImageMemory(g_vk.dev, imported, imported_mem, 0), "vkBindImageMemory(import)"))
        return -1;

    VkImageCreateInfo lin_info = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D, .format = fmt,
        .extent = { width, height, 1 }, .mipLevels = 1, .arrayLayers = 1,
        .samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_LINEAR,
        .usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT, .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
        .initialLayout = VK_IMAGE_LAYOUT_PREINITIALIZED,
    };
    VkImage linear_img;
    if (vk_check(g_vk.CreateImage(g_vk.dev, &lin_info, NULL, &linear_img), "vkCreateImage(linear)")) return -1;
    VkMemoryRequirements lin_reqs;
    g_vk.GetImageMemoryRequirements(g_vk.dev, linear_img, &lin_reqs);
    VkMemoryAllocateInfo lin_alloc = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = lin_reqs.size,
        .memoryTypeIndex = vk_find_mem_type(lin_reqs.memoryTypeBits,
                                            VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
                                                VK_MEMORY_PROPERTY_HOST_COHERENT_BIT),
    };
    VkDeviceMemory linear_mem;
    if (vk_check(g_vk.AllocateMemory(g_vk.dev, &lin_alloc, NULL, &linear_mem), "vkAllocateMemory(linear)"))
        return -1;
    if (vk_check(g_vk.BindImageMemory(g_vk.dev, linear_img, linear_mem, 0), "vkBindImageMemory(linear)"))
        return -1;

    VkImageSubresource lin_sub = { .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT };
    VkSubresourceLayout lin_layout;
    g_vk.GetImageSubresourceLayout(g_vk.dev, linear_img, &lin_sub, &lin_layout);

    g_vk.BeginCommandBuffer(g_vk.cmd, &(VkCommandBufferBeginInfo){
                                          .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO });
    VkImageMemoryBarrier to_src = { .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
                                    .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
                                    .newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                                    .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
                                    .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .image = imported,
                                    .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 },
                                    .dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT };
    VkImageMemoryBarrier to_dst = { .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
                                    .oldLayout = VK_IMAGE_LAYOUT_PREINITIALIZED,
                                    .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                                    .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
                                    .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .image = linear_img,
                                    .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 },
                                    .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT };
    VkImageMemoryBarrier both[2] = { to_src, to_dst };
    g_vk.CmdPipelineBarrier(g_vk.cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
                            0, 0, NULL, 0, NULL, 2, both);
    VkImageCopy region = { .srcSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 },
                          .dstSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 },
                          .extent = { width, height, 1 } };
    g_vk.CmdCopyImage(g_vk.cmd, imported, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, linear_img,
                      VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
    g_vk.EndCommandBuffer(g_vk.cmd);
    VkSubmitInfo submit = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1,
                            .pCommandBuffers = &g_vk.cmd };
    if (vk_check(g_vk.QueueSubmit(g_vk.queue, 1, &submit, VK_NULL_HANDLE), "vkQueueSubmit")) return -1;
    g_vk.QueueWaitIdle(g_vk.queue);

    uint32_t bpp = (fmt == VK_FORMAT_R8_UNORM) ? 1 : 2;
    *out_size = (size_t)width * height * bpp;
    *out_data = malloc(*out_size);
    void *mapped;
    if (vk_check(g_vk.MapMemory(g_vk.dev, linear_mem, 0, lin_reqs.size, 0, &mapped), "vkMapMemory"))
        return -1;
    for (uint32_t y = 0; y < height; y++)
        memcpy(*out_data + (size_t)y * width * bpp,
               (uint8_t *)mapped + lin_layout.offset + (size_t)y * lin_layout.rowPitch,
               (size_t)width * bpp);
    g_vk.UnmapMemory(g_vk.dev, linear_mem);

    g_vk.DestroyImage(g_vk.dev, imported, NULL);
    g_vk.DestroyImage(g_vk.dev, linear_img, NULL);
    g_vk.FreeMemory(g_vk.dev, imported_mem, NULL);
    g_vk.FreeMemory(g_vk.dev, linear_mem, NULL);
    return 0;
}

/* ------------------------------------------------------------------ *
 * Persistent VA-API decode state.
 * ------------------------------------------------------------------ */
typedef struct {
    int drm_fd;
    VADisplay dpy;
    VAConfigID config;
    VAConfigID vpp_config;
    unsigned int width, height;
    int have_context;
    VASurfaceID surfaces[3];
    VAContextID context;
    VASurfaceID vpp_out;
    VAContextID vpp_context;
} DecodeState;

static DecodeState g_dec;
static int g_dec_ready;
static uint8_t g_out_buf[8 * 1024 * 1024];

static int decode_ensure_resolution(unsigned int width, unsigned int height) {
    if (g_dec.have_context && g_dec.width == width && g_dec.height == height) return 0;
    if (g_dec.have_context) {
        vaDestroyContext(g_dec.dpy, g_dec.context);
        vaDestroyContext(g_dec.dpy, g_dec.vpp_context);
        vaDestroySurfaces(g_dec.dpy, g_dec.surfaces, 3);
        vaDestroySurfaces(g_dec.dpy, &g_dec.vpp_out, 1);
        g_dec.have_context = 0;
    }

    uint64_t linear_modifier = 0; /* DRM_FORMAT_MOD_LINEAR - requested but not
                                   * honored by this driver for the decode
                                   * target (see tier6's own README); kept
                                   * anyway since it's harmless and correct
                                   * for the VPP output path on drivers that
                                   * *do* honor it. */
    VADRMFormatModifierList modifier_list = { .num_modifiers = 1, .modifiers = &linear_modifier };
    VASurfaceAttrib surface_attrib = {
        .type = VASurfaceAttribDRMFormatModifiers,
        .flags = VA_SURFACE_ATTRIB_SETTABLE,
        .value = { .type = VAGenericValueTypePointer, .value = { .p = &modifier_list } },
    };
    CHECK_VA(vaCreateSurfaces(g_dec.dpy, VA_RT_FORMAT_YUV420, align16(width), align16(height),
                              g_dec.surfaces, 3, &surface_attrib, 1),
             "vaCreateSurfaces(decode)");
    CHECK_VA(vaCreateContext(g_dec.dpy, g_dec.config, (int)align16(width), (int)align16(height),
                             VA_PROGRESSIVE, g_dec.surfaces, 3, &g_dec.context),
             "vaCreateContext(decode)");
    CHECK_VA(vaCreateSurfaces(g_dec.dpy, VA_RT_FORMAT_YUV420, align16(width), align16(height),
                              &g_dec.vpp_out, 1, &surface_attrib, 1),
             "vaCreateSurfaces(vpp_out)");
    CHECK_VA(vaCreateContext(g_dec.dpy, g_dec.vpp_config, (int)align16(width), (int)align16(height),
                             VA_PROGRESSIVE, &g_dec.vpp_out, 1, &g_dec.vpp_context),
             "vaCreateContext(vpp)");

    g_dec.width = width;
    g_dec.height = height;
    g_dec.have_context = 1;
    return 0;
}

int decode_h264_init(void) {
    memset(&g_dec, 0, sizeof(g_dec));
    g_dec.drm_fd = open(DRM_DEVICE, O_RDWR);
    if (g_dec.drm_fd < 0) { perror("decode: open " DRM_DEVICE); return -1; }
    g_dec.dpy = vaGetDisplayDRM(g_dec.drm_fd);
    if (!g_dec.dpy) { fprintf(stderr, "decode: vaGetDisplayDRM failed\n"); return -1; }

    /* libva's own driver auto-detection (by the render node's kernel driver
     * name) doesn't reliably resolve to nvidia-vaapi-driver for an NVIDIA
     * render node - the standalone spike this was ported from needed
     * LIBVA_DRIVER_NAME=nvidia set explicitly on its own command line for
     * the same reason. This daemon may also run vaInitialize() for the
     * existing AMD/Intel encode path in the same process (daemon.c's own
     * vaapi_state_init(), on a host that has both a decode and an encode
     * GPU); scoping the env var to just this call - save whatever was
     * there, set it, initialize, put it back - means the two init calls
     * don't clobber each other regardless of which one main() calls first. */
    const char *prev_driver_name = getenv("LIBVA_DRIVER_NAME");
    char *prev_driver_name_copy = prev_driver_name ? strdup(prev_driver_name) : NULL;
    setenv("LIBVA_DRIVER_NAME", "nvidia", 1);
    int major, minor;
    VAStatus init_status = vaInitialize(g_dec.dpy, &major, &minor);
    if (prev_driver_name_copy) {
        setenv("LIBVA_DRIVER_NAME", prev_driver_name_copy, 1);
        free(prev_driver_name_copy);
    } else {
        unsetenv("LIBVA_DRIVER_NAME");
    }
    CHECK_VA(init_status, "vaInitialize");
    fprintf(stderr, "decode: VA-API %d.%d, driver: %s\n", major, minor,
            vaQueryVendorString(g_dec.dpy));

    VAConfigAttrib attrib = { .type = VAConfigAttribRTFormat };
    CHECK_VA(vaGetConfigAttributes(g_dec.dpy, VAProfileH264ConstrainedBaseline, VAEntrypointVLD,
                                   &attrib, 1),
             "vaGetConfigAttributes");
    if (!(attrib.value & VA_RT_FORMAT_YUV420)) {
        fprintf(stderr, "decode: no VAEntrypointVLD/YUV420 support on this GPU\n");
        return -1;
    }
    VAConfigAttrib cfg_attrib = { .type = VAConfigAttribRTFormat, .value = VA_RT_FORMAT_YUV420 };
    CHECK_VA(vaCreateConfig(g_dec.dpy, VAProfileH264ConstrainedBaseline, VAEntrypointVLD,
                            &cfg_attrib, 1, &g_dec.config),
             "vaCreateConfig(decode)");
    CHECK_VA(vaCreateConfig(g_dec.dpy, VAProfileNone, VAEntrypointVideoProc, NULL, 0,
                            &g_dec.vpp_config),
             "vaCreateConfig(vpp)");

    if (vk_init() != 0) {
        fprintf(stderr, "decode: Vulkan init failed - decode unavailable on this host\n");
        return -1;
    }
    g_vk_ready = 1;
    g_dec_ready = 1;
    return 0;
}

int decode_h264_frame(const uint8_t *bitstream, size_t bitstream_size, const uint8_t **out_data,
                      size_t *out_size, uint32_t *out_width, uint32_t *out_height) {
    if (!g_dec_ready || !g_vk_ready) {
        fprintf(stderr, "decode: decode_h264_init() was never called or failed\n");
        return -1;
    }

    NalUnit nals[8];
    int nal_count = extract_nals(bitstream, bitstream_size, nals, 8);
    SpsInfo sps; memset(&sps, 0, sizeof(sps));
    PpsInfo pps; memset(&pps, 0, sizeof(pps));
    NalUnit *idr_nal = NULL;
    int have_sps = 0, have_pps = 0;

    for (int i = 0; i < nal_count; i++) {
        size_t rbsp_size;
        uint8_t *rbsp = deescape_rbsp(nals[i].data, nals[i].size, &rbsp_size);
        if (nals[i].nal_unit_type == 7 && !have_sps) {
            if (parse_sps(rbsp, rbsp_size, &sps) != 0) { free(rbsp); return -1; }
            have_sps = 1;
        } else if (nals[i].nal_unit_type == 8 && !have_pps) {
            if (parse_pps(rbsp, rbsp_size, &pps) != 0) { free(rbsp); return -1; }
            have_pps = 1;
        } else if (nals[i].nal_unit_type == 5 && !idr_nal) {
            idr_nal = &nals[i];
        }
        free(rbsp);
        if (have_sps && have_pps && idr_nal) break;
    }
    if (!have_sps || !have_pps || !idr_nal) {
        fprintf(stderr, "decode: missing SPS(%d)/PPS(%d)/IDR(%p) in this buffer\n", have_sps,
                have_pps, (void *)idr_nal);
        return -1;
    }

    unsigned int width_mbs = sps.pic_width_in_mbs_minus1 + 1;
    unsigned int height_map_units = sps.pic_height_in_map_units_minus1 + 1;
    unsigned int height_mbs = height_map_units * (2 - sps.frame_mbs_only_flag);
    unsigned int width = width_mbs * 16;
    unsigned int height = height_mbs * 16;

    size_t slice_rbsp_size;
    uint8_t *slice_rbsp = deescape_rbsp(idr_nal->data, idr_nal->size, &slice_rbsp_size);
    SliceHeader sh; memset(&sh, 0, sizeof(sh));
    int shr = parse_slice_header(slice_rbsp, slice_rbsp_size, idr_nal->nal_unit_type,
                                 idr_nal->nal_ref_idc, &sps, &pps, &sh);
    free(slice_rbsp);
    if (shr != 0) return -1;
    unsigned int slice_data_bit_offset =
        8 + escaped_bit_offset(idr_nal->data, idr_nal->size, sh.header_bits);

    if (decode_ensure_resolution(width, height) != 0) return -1;

    CHECK_VA(vaBeginPicture(g_dec.dpy, g_dec.context, g_dec.surfaces[0]), "vaBeginPicture");

    VAPictureParameterBufferH264 pic_param;
    memset(&pic_param, 0, sizeof(pic_param));
    pic_param.CurrPic.picture_id = g_dec.surfaces[0];
    pic_param.CurrPic.frame_idx = sh.frame_num;
    pic_param.CurrPic.TopFieldOrderCnt = (int)sh.pic_order_cnt_lsb;
    pic_param.CurrPic.BottomFieldOrderCnt = (int)sh.pic_order_cnt_lsb;
    for (int i = 0; i < 16; i++) pic_param.ReferenceFrames[i].picture_id = VA_INVALID_SURFACE;
    pic_param.picture_width_in_mbs_minus1 = sps.pic_width_in_mbs_minus1;
    pic_param.picture_height_in_mbs_minus1 = sps.pic_height_in_map_units_minus1;
    pic_param.num_ref_frames = sps.max_num_ref_frames;
    pic_param.seq_fields.bits.chroma_format_idc = 1;
    pic_param.seq_fields.bits.frame_mbs_only_flag = sps.frame_mbs_only_flag;
    pic_param.seq_fields.bits.pic_order_cnt_type = sps.pic_order_cnt_type;
    pic_param.seq_fields.bits.log2_max_frame_num_minus4 = sps.log2_max_frame_num_minus4;
    pic_param.seq_fields.bits.log2_max_pic_order_cnt_lsb_minus4 = sps.log2_max_pic_order_cnt_lsb_minus4;
    pic_param.pic_init_qp_minus26 = pps.pic_init_qp_minus26;
    pic_param.chroma_qp_index_offset = pps.chroma_qp_index_offset;
    pic_param.second_chroma_qp_index_offset = pps.chroma_qp_index_offset;
    pic_param.pic_fields.bits.entropy_coding_mode_flag = pps.entropy_coding_mode_flag;
    pic_param.pic_fields.bits.weighted_pred_flag = pps.weighted_pred_flag;
    pic_param.pic_fields.bits.weighted_bipred_idc = pps.weighted_bipred_idc;
    pic_param.pic_fields.bits.deblocking_filter_control_present_flag =
        pps.deblocking_filter_control_present_flag;
    pic_param.pic_fields.bits.redundant_pic_cnt_present_flag = pps.redundant_pic_cnt_present_flag;
    pic_param.pic_fields.bits.reference_pic_flag = (idr_nal->nal_ref_idc != 0);
    pic_param.pic_fields.bits.pic_order_present_flag = pps.pic_order_present_flag;

    VABufferID pic_param_buf;
    CHECK_VA(vaCreateBuffer(g_dec.dpy, g_dec.context, VAPictureParameterBufferType,
                            sizeof(pic_param), 1, &pic_param, &pic_param_buf),
             "vaCreateBuffer(pic_param)");
    CHECK_VA(vaRenderPicture(g_dec.dpy, g_dec.context, &pic_param_buf, 1), "vaRenderPicture(pic_param)");

    VAIQMatrixBufferH264 iq_matrix;
    memset(&iq_matrix, 0, sizeof(iq_matrix));
    memset(iq_matrix.ScalingList4x4, 16, sizeof(iq_matrix.ScalingList4x4));
    memset(iq_matrix.ScalingList8x8, 16, sizeof(iq_matrix.ScalingList8x8));
    VABufferID iq_matrix_buf;
    CHECK_VA(vaCreateBuffer(g_dec.dpy, g_dec.context, VAIQMatrixBufferType, sizeof(iq_matrix), 1,
                            &iq_matrix, &iq_matrix_buf),
             "vaCreateBuffer(iq_matrix)");
    CHECK_VA(vaRenderPicture(g_dec.dpy, g_dec.context, &iq_matrix_buf, 1), "vaRenderPicture(iq_matrix)");

    VASliceParameterBufferH264 slice_param;
    memset(&slice_param, 0, sizeof(slice_param));
    slice_param.slice_data_size = (unsigned int)idr_nal->size + 1;
    slice_param.slice_data_offset = 0;
    slice_param.slice_data_flag = VA_SLICE_DATA_FLAG_ALL;
    slice_param.slice_data_bit_offset = (uint16_t)slice_data_bit_offset;
    slice_param.first_mb_in_slice = sh.first_mb_in_slice;
    slice_param.slice_type = sh.slice_type % 5;
    slice_param.num_ref_idx_l0_active_minus1 = pps.num_ref_idx_l0_active_minus1;
    slice_param.num_ref_idx_l1_active_minus1 = pps.num_ref_idx_l1_active_minus1;
    slice_param.slice_qp_delta = sh.slice_qp_delta;
    for (int i = 0; i < 32; i++) {
        slice_param.RefPicList0[i].picture_id = VA_INVALID_SURFACE;
        slice_param.RefPicList1[i].picture_id = VA_INVALID_SURFACE;
    }
    VABufferID slice_param_buf;
    CHECK_VA(vaCreateBuffer(g_dec.dpy, g_dec.context, VASliceParameterBufferType,
                            sizeof(slice_param), 1, &slice_param, &slice_param_buf),
             "vaCreateBuffer(slice_param)");
    CHECK_VA(vaRenderPicture(g_dec.dpy, g_dec.context, &slice_param_buf, 1), "vaRenderPicture(slice_param)");

    /* +1/-1 for the NAL header byte - see tier6-vaapi-decode/README.md's
     * own bug #4 for the full story of why this specific byte matters. */
    VABufferID slice_data_buf;
    CHECK_VA(vaCreateBuffer(g_dec.dpy, g_dec.context, VASliceDataBufferType,
                            (unsigned int)idr_nal->size + 1, 1, (void *)(idr_nal->data - 1),
                            &slice_data_buf),
             "vaCreateBuffer(slice_data)");
    CHECK_VA(vaRenderPicture(g_dec.dpy, g_dec.context, &slice_data_buf, 1), "vaRenderPicture(slice_data)");

    CHECK_VA(vaEndPicture(g_dec.dpy, g_dec.context), "vaEndPicture");
    CHECK_VA(vaSyncSurface(g_dec.dpy, g_dec.surfaces[0]), "vaSyncSurface");

    /* VPP blit to a second surface before reading anything back - see
     * decode_h264.h/tier6's own README for why (NVDEC's own decode target
     * stays tiled no matter what's requested of it). */
    CHECK_VA(vaBeginPicture(g_dec.dpy, g_dec.vpp_context, g_dec.vpp_out), "vaBeginPicture(vpp)");
    VABufferID vpp_buf;
    VAProcPipelineParameterBuffer *vpp_param;
    CHECK_VA(vaCreateBuffer(g_dec.dpy, g_dec.vpp_context, VAProcPipelineParameterBufferType,
                            sizeof(VAProcPipelineParameterBuffer), 1, NULL, &vpp_buf),
             "vaCreateBuffer(vpp)");
    CHECK_VA(vaMapBuffer(g_dec.dpy, vpp_buf, (void **)&vpp_param), "vaMapBuffer(vpp)");
    memset(vpp_param, 0, sizeof(*vpp_param));
    vpp_param->surface = g_dec.surfaces[0];
    vpp_param->filter_flags = VA_FRAME_PICTURE;
    CHECK_VA(vaUnmapBuffer(g_dec.dpy, vpp_buf), "vaUnmapBuffer(vpp)");
    CHECK_VA(vaRenderPicture(g_dec.dpy, g_dec.vpp_context, &vpp_buf, 1), "vaRenderPicture(vpp)");
    CHECK_VA(vaEndPicture(g_dec.dpy, g_dec.vpp_context), "vaEndPicture(vpp)");
    CHECK_VA(vaSyncSurface(g_dec.dpy, g_dec.vpp_out), "vaSyncSurface(vpp_out)");

    VADRMPRIMESurfaceDescriptor prime_desc;
    CHECK_VA(vaExportSurfaceHandle(g_dec.dpy, g_dec.vpp_out, VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2,
                                   VA_EXPORT_SURFACE_READ_ONLY | VA_EXPORT_SURFACE_SEPARATE_LAYERS,
                                   &prime_desc),
             "vaExportSurfaceHandle");

    size_t total = 0;
    int failed = 0;
    for (uint32_t li = 0; li < prime_desc.num_layers && !failed; li++) {
        uint32_t obj_idx = prime_desc.layers[li].object_index[0];
        int fd = prime_desc.objects[obj_idx].fd;
        uint64_t modifier = prime_desc.objects[obj_idx].drm_format_modifier;
        unsigned int plane_height = (li == 0) ? height : height / 2;
        unsigned int plane_width = (li == 0) ? width : width / 2;
        VkFormat vk_fmt = (prime_desc.layers[li].drm_format == 0x20203852) ? VK_FORMAT_R8_UNORM
                                                                            : VK_FORMAT_R8G8_UNORM;
        uint8_t *plane_data = NULL;
        size_t plane_size = 0;
        if (vk_detile(fd, vk_fmt, plane_width, plane_height, modifier,
                      prime_desc.objects[obj_idx].size, &plane_data, &plane_size) != 0) {
            failed = 1;
        } else if (total + plane_size <= sizeof(g_out_buf)) {
            memcpy(g_out_buf + total, plane_data, plane_size);
            total += plane_size;
        } else {
            fprintf(stderr, "decode: decoded frame too large for the static output buffer\n");
            failed = 1;
        }
        free(plane_data);
    }
    for (uint32_t i = 0; i < prime_desc.num_objects; i++) close(prime_desc.objects[i].fd);
    if (failed) return -1;

    *out_data = g_out_buf;
    *out_size = total;
    *out_width = width;
    *out_height = height;
    return 0;
}
