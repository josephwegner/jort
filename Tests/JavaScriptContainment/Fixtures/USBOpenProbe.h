/* Nonshipping authority probe. Opening this user-client connection and closing
 * it does not invoke a USB operation, seize the device, or send a credential
 * request. Keep the positive control and sandbox attempt identical. */
#ifndef JORT_USB_OPEN_PROBE_H
#define JORT_USB_OPEN_PROBE_H

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <stdbool.h>

typedef struct {
    void *library;
    CFMutableDictionaryRef (*matching)(const char *);
    CFMutableDictionaryRef (*matching_id)(uint64_t);
    kern_return_t (*services)(mach_port_t, CFDictionaryRef, io_iterator_t *);
    io_service_t (*service)(mach_port_t, CFDictionaryRef);
    io_object_t (*next)(io_iterator_t);
    kern_return_t (*release)(io_object_t);
    CFTypeRef (*property)(io_registry_entry_t, CFStringRef, CFAllocatorRef, IOOptionBits);
    kern_return_t (*registry_id)(io_registry_entry_t, uint64_t *);
    kern_return_t (*open)(io_service_t, task_port_t, uint32_t, io_connect_t *);
    kern_return_t (*close)(io_connect_t);
} JortUSBProbe;

static inline bool jort_usb_load(JortUSBProbe *api) {
    api->library = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY | RTLD_LOCAL);
    if (!api->library) return false;
    api->matching = dlsym(api->library, "IOServiceMatching");
    api->matching_id = dlsym(api->library, "IORegistryEntryIDMatching");
    api->services = dlsym(api->library, "IOServiceGetMatchingServices");
    api->service = dlsym(api->library, "IOServiceGetMatchingService");
    api->next = dlsym(api->library, "IOIteratorNext");
    api->release = dlsym(api->library, "IOObjectRelease");
    api->property = dlsym(api->library, "IORegistryEntryCreateCFProperty");
    api->registry_id = dlsym(api->library, "IORegistryEntryGetRegistryEntryID");
    api->open = dlsym(api->library, "IOServiceOpen");
    api->close = dlsym(api->library, "IOServiceClose");
    return api->matching && api->matching_id && api->services && api->service
        && api->next && api->release && api->property && api->registry_id && api->open && api->close;
}

static inline uint64_t jort_usb_yubikey(JortUSBProbe *api) {
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (api->services(MACH_PORT_NULL, api->matching("IOUSBHostDevice"), &iterator) != KERN_SUCCESS) return 0;
    uint64_t identifier = 0;
    io_service_t service;
    while ((service = api->next(iterator))) {
        CFTypeRef vendor = api->property(service, CFSTR("idVendor"), kCFAllocatorDefault, 0);
        int value = 0;
        if (vendor && CFGetTypeID(vendor) == CFNumberGetTypeID()
            && CFNumberGetValue(vendor, kCFNumberIntType, &value) && value == 0x1050) {
            (void)api->registry_id(service, &identifier);
        }
        if (vendor) CFRelease(vendor);
        api->release(service);
        if (identifier) break;
    }
    api->release(iterator);
    return identifier;
}

static inline kern_return_t jort_usb_open_close(JortUSBProbe *api, uint64_t identifier,
    bool *present, bool *opened) {
    *opened = false;
    io_service_t service = api->service(MACH_PORT_NULL, api->matching_id(identifier));
    *present = service != IO_OBJECT_NULL;
    if (!*present) return kIOReturnNoDevice;
    io_connect_t connection = IO_OBJECT_NULL;
    kern_return_t status = api->open(service, mach_task_self(), 0, &connection);
    if (status == KERN_SUCCESS) {
        *opened = true;
        kern_return_t closed = api->close(connection);
        if (closed != KERN_SUCCESS) status = closed;
    }
    api->release(service);
    return status;
}

#endif
