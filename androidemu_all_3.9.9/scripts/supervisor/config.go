package main

import (
	"os"
	"strconv"
)

type Config struct {
	AndroidContainer string
	WebrtcContainer  string
	Interval         int
	HTTPPort         int
	VarDir           string
	AppDir           string
	StablePeriod     int // agent稳定期（秒）
}

func LoadConfig() (*Config, error) {
	c := &Config{
		AndroidContainer: getEnv("ANDROIDEMU_ANDROID_NAME", "androidemu-android"),
		WebrtcContainer:  getEnv("ANDROIDEMU_WEBRTC_NAME", "androidemu-webrtc"),
		Interval:         getEnvInt("ANDROIDEMU_MONITOR_INTERVAL", 30),
		HTTPPort:         getEnvInt("ANDROIDEMU_SUPERVISOR_PORT", 18444),
		VarDir:           getEnv("TRIM_PKGVAR", "/var/apps/androidemu/var"),
		AppDir:           getEnv("TRIM_APPDEST", "/var/apps/androidemu/target"),
		StablePeriod:     getEnvInt("ANDROIDEMU_STABLE_PERIOD", 120),
	}
	return c, nil
}

func getEnv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func getEnvInt(key string, def int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}
