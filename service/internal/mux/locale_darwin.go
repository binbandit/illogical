package mux

/*
#cgo LDFLAGS: -framework CoreFoundation
#include <CoreFoundation/CoreFoundation.h>

static int il_current_locale(char *out, int capacity) {
    CFLocaleRef locale = CFLocaleCopyCurrent();
    if (locale == NULL) return 0;
    Boolean ok = CFStringGetCString(CFLocaleGetIdentifier(locale), out, capacity, kCFStringEncodingUTF8);
    CFRelease(locale);
    return ok;
}
*/
import "C"

import (
	"os"
	"strings"
)

// defaultLocale mirrors Terminal.app: the user's region as a UTF-8 locale.
func defaultLocale() string {
	var identifier [128]C.char
	if C.il_current_locale(&identifier[0], C.int(len(identifier))) != 0 {
		if locale := posixLocale(C.GoString(&identifier[0])); locale != "" {
			if _, err := os.Stat("/usr/share/locale/" + locale); err == nil {
				return locale
			}
		}
	}
	return "en_US.UTF-8"
}

// posixLocale turns a CFLocale identifier such as "en_AU@rg=auzzzz" or
// "zh-Hans_CN" into "en_AU.UTF-8" or "zh_CN.UTF-8".
func posixLocale(identifier string) string {
	identifier, _, _ = strings.Cut(identifier, "@")
	language, rest, _ := strings.Cut(identifier, "_")
	language, _, _ = strings.Cut(language, "-")
	region := rest
	if i := strings.LastIndex(rest, "_"); i >= 0 {
		region = rest[i+1:]
	}
	if language == "" || region == "" {
		return ""
	}
	return language + "_" + region + ".UTF-8"
}
