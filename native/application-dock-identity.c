#include <crt_externs.h>
#include <CoreGraphics/CGGeometry.h>
#include <dlfcn.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void (*original_set_icon)(id, SEL, id);
static BOOL (*original_set_policy)(id, SEL, long);
static void (*original_finish_launching)(id, SEL);
static void (*original_set_main_menu)(id, SEL, id);
static int background_process;
static id dock_icon;
static char *icon_path;
static void (*original_set_mask)(id, SEL, CGRect);
static int direct_keyboard;
static void (*original_toggle_fullscreen)(id, SEL, id);
static BOOL (*original_validate_menu_item)(id, SEL, id);

static BOOL native_fullscreen(id window)
{
    return (((unsigned long (*)(id, SEL))objc_msgSend)(window, sel_registerName("styleMask")) & (1UL << 14)) != 0;
}

static void toggle_fullscreen(id window, SEL command, id sender)
{
    // Wine marks a native fullscreen window maximized, which blocks its own
    // exit command. AppKit can exit this state without another Wine modeset.
    if (native_fullscreen(window)) {
        IMP toggle = class_getMethodImplementation(objc_getClass("NSWindow"), command);
        ((void (*)(id, SEL, id))toggle)(window, command, sender);
    } else original_toggle_fullscreen(window, command, sender);
}

static BOOL validate_menu_item(id window, SEL command, id item)
{
    if (native_fullscreen(window) && ((SEL (*)(id, SEL))objc_msgSend)(item,
            sel_registerName("action")) == sel_registerName("toggleFullScreen:")) return YES;
    return original_validate_menu_item(window, command, item);
}

static id direct_input_context(id view, SEL command)
{
    (void)view;
    (void)command;
    // Let Wine deliver the original virtual key instead of VK_PROCESSKEY.
    // This is opt-in because games can also contain text composition fields.
    return NULL;
}

static void set_window_mask(id window, SEL command, CGRect rect)
{
    id view = ((id (*)(id, SEL))objc_msgSend)(window, sel_registerName("contentView"));
    id layer = ((id (*)(id, SEL))objc_msgSend)(view, sel_registerName("layer"));
    double scale = layer ? ((double (*)(id, SEL))objc_msgSend)(layer, sel_registerName("contentsScale")) : 1.0;
    // Wine 11 passes pixel coordinates to a mask drawn in Cocoa points. The
    // view's scale follows Wine's active Retina mode, including mode changes.
    if (scale == 2.0) {
        rect.origin.x /= 2.0;
        rect.origin.y /= 2.0;
        rect.size.width /= 2.0;
        rect.size.height /= 2.0;
    }
    original_set_mask(window, command, rect);
}

static SEL selector(const char *name) { return sel_registerName(name); }

static id string(const char *value)
{
    return ((id (*)(id, SEL, const char *))objc_msgSend)(
        (id)objc_getClass("NSString"), selector("stringWithUTF8String:"), value);
}

static id menu(id title)
{
    id allocated = ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("NSMenu"), selector("alloc"));
    id result = ((id (*)(id, SEL, id))objc_msgSend)(allocated, selector("initWithTitle:"), title);
    return ((id (*)(id, SEL))objc_msgSend)(result, selector("autorelease"));
}

static void ensure_window_menu(id application, id main)
{
    long count = ((long (*)(id, SEL))objc_msgSend)(main, selector("numberOfItems"));
    for (long index = 0; index < count; index++) {
        id item = ((id (*)(id, SEL, long))objc_msgSend)(main, selector("itemAtIndex:"), index);
        id submenu = ((id (*)(id, SEL))objc_msgSend)(item, selector("submenu"));
        if (submenu && ((long (*)(id, SEL, id, SEL))objc_msgSend)(submenu,
                selector("indexOfItemWithTarget:andAction:"), NULL, selector("toggleFullScreen:")) >= 0)
            return;
    }
    // Regular per-application identities bypass Wine's default Window menu.
    // Keep a visible exit route when the fullscreen title bar is hidden.
    id submenu = menu(string("Window"));
    const char *titles[] = {"Minimize", "Zoom", "Toggle Full Screen"};
    const char *actions[] = {"performMiniaturize:", "performZoom:", "toggleFullScreen:"};
    const char *keys[] = {"m", "", "f"};
    for (int index = 0; index < 3; index++) {
        id entry = ((id (*)(id, SEL, id, SEL, id))objc_msgSend)(submenu,
            selector("addItemWithTitle:action:keyEquivalent:"), string(titles[index]),
            selector(actions[index]), string(keys[index]));
        unsigned long modifiers = (1UL << 20) | (index == 2 ? 1UL << 18 : 0);
        ((void (*)(id, SEL, unsigned long))objc_msgSend)(entry, selector("setKeyEquivalentModifierMask:"), modifiers);
    }
    id item = ((id (*)(id, SEL, id, SEL, id))objc_msgSend)(main,
        selector("addItemWithTitle:action:keyEquivalent:"), string("Window"), NULL, string(""));
    ((void (*)(id, SEL, id))objc_msgSend)(item, selector("setSubmenu:"), submenu);
    ((void (*)(id, SEL, id))objc_msgSend)(application, selector("setWindowsMenu:"), submenu);
}

static void set_main_menu(id application, SEL command, id main)
{
    if (background_process) {
        original_set_main_menu(application, command, main);
        return;
    }
    id item = NULL;
    if (main && ((long (*)(id, SEL))objc_msgSend)(main, selector("numberOfItems")))
        item = ((id (*)(id, SEL, long))objc_msgSend)(main, selector("itemAtIndex:"), 0);
    id submenu = item ? ((id (*)(id, SEL))objc_msgSend)(item, selector("submenu")) : NULL;
    long count = submenu ? ((long (*)(id, SEL))objc_msgSend)(submenu, selector("numberOfItems")) : 0;
    for (long index = 0; index < count; index++) {
        id entry = ((id (*)(id, SEL, long))objc_msgSend)(submenu, selector("itemAtIndex:"), index);
        if (((SEL (*)(id, SEL))objc_msgSend)(entry, selector("action")) == selector("terminate:")) {
            ensure_window_menu(application, main);
            original_set_main_menu(application, command, main);
            return;
        }
    }

    // CFProcessPath makes Wine start as a regular app, skipping its default
    // menu setup. Use terminate: so Wine still handles normal quit requests.
    id bundle = ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("NSBundle"), selector("mainBundle"));
    id name = ((id (*)(id, SEL, id))objc_msgSend)(bundle, selector("objectForInfoDictionaryKey:"), string("CFBundleName"));
    if (!name) name = string("Application");
    if (!main) main = menu(name);
    if (!item)
        item = ((id (*)(id, SEL, id, SEL, id))objc_msgSend)(main,
            selector("addItemWithTitle:action:keyEquivalent:"), name, NULL, string(""));
    if (!submenu) submenu = menu(name);
    if (count) {
        id separator = ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("NSMenuItem"), selector("separatorItem"));
        ((void (*)(id, SEL, id))objc_msgSend)(submenu, selector("addItem:"), separator);
    }
    id title = ((id (*)(id, SEL, id))objc_msgSend)(string("Quit "), selector("stringByAppendingString:"), name);
    id quit = ((id (*)(id, SEL, id, SEL, id))objc_msgSend)(submenu,
        selector("addItemWithTitle:action:keyEquivalent:"), title, selector("terminate:"), string("q"));
    ((void (*)(id, SEL, id))objc_msgSend)(quit, selector("setTarget:"), application);
    ((void (*)(id, SEL, unsigned long))objc_msgSend)(quit, selector("setKeyEquivalentModifierMask:"), 1UL << 20);
    ((void (*)(id, SEL, id))objc_msgSend)(item, selector("setSubmenu:"), submenu);
    ensure_window_menu(application, main);
    original_set_main_menu(application, command, main);
}

static void finish_launching(id application, SEL command)
{
    if (direct_keyboard) {
        Class view = objc_getClass("WineContentView");
        Method method = view ? class_getInstanceMethod(view, selector("inputContext")) : NULL;
        if (method) method_setImplementation(method, (IMP)direct_input_context);
    }
    if (getenv("TRAVERSE_RETINA_MASK_FIX") && !original_set_mask) {
        Class window = objc_getClass("WineWindow");
        Method method = window ? class_getInstanceMethod(window, selector("setMask:")) : NULL;
        if (method) {
            original_set_mask = (void *)method_getImplementation(method);
            method_setImplementation(method, (IMP)set_window_mask);
        }
        method = window ? class_getInstanceMethod(window, selector("toggleFullScreen:")) : NULL;
        if (method) {
            original_toggle_fullscreen = (void *)method_getImplementation(method);
            class_replaceMethod(window, selector("toggleFullScreen:"), (IMP)toggle_fullscreen, method_getTypeEncoding(method));
        }
        method = window ? class_getInstanceMethod(window, selector("validateMenuItem:")) : NULL;
        if (method) {
            original_validate_menu_item = (void *)method_getImplementation(method);
            class_replaceMethod(window, selector("validateMenuItem:"), (IMP)validate_menu_item, method_getTypeEncoding(method));
        }
    }
    original_finish_launching(application, command);
    id main = ((id (*)(id, SEL))objc_msgSend)(application, selector("mainMenu"));
    set_main_menu(application, selector("setMainMenu:"), main);
}

static void set_application_icon(id application, SEL command, id image)
{
    if (!dock_icon && icon_path && *icon_path) {
        id path = ((id (*)(id, SEL, const char *))objc_msgSend)(
            (id)objc_getClass("NSString"), selector("stringWithUTF8String:"), icon_path);
        id allocated = ((id (*)(id, SEL))objc_msgSend)(
            (id)objc_getClass("NSImage"), selector("alloc"));
        dock_icon = ((id (*)(id, SEL, id))objc_msgSend)(
            allocated, selector("initWithContentsOfFile:"), path);
    }
    original_set_icon(application, command, dock_icon ? dock_icon : image);
}

static BOOL set_activation_policy(id application, SEL command, long policy)
{
    // Keep Wine's background shell and Steam client out of the Dock. Their
    // application windows belong to other processes (including steamwebhelper).
    if (background_process && policy == 0) policy = 1; // Regular -> Accessory
    return original_set_policy(application, command, policy);
}

static char *normalized_path(const char *path)
{
    char *result = strdup(path);
    for (char *p = result; *p; p++) if (*p == '\\') *p = '/';
    return result;
}

__attribute__((constructor)) static void configure_application_identity(void)
{
    const char *manifest = getenv("TRAVERSE_DOCK_IDENTITIES");
    if (!manifest) return;
    char **argv = *_NSGetArgv();
    int argc = *_NSGetArgc();
    char *image = NULL, *archive = NULL;
    for (int i = 1; i < argc; i++) {
        size_t length = strlen(argv[i]);
        if (!image && length >= 4 && !strcasecmp(argv[i] + length - 4, ".exe"))
            image = normalized_path(argv[i]);
        if (!strcmp(argv[i], "-jar") && i + 1 < argc) archive = normalized_path(argv[i + 1]);
    }
    FILE *file = fopen(manifest, "rb");
    if (file) {
        fseek(file, 0, SEEK_END);
        long size = ftell(file);
        rewind(file);
        char *data = size > 0 ? malloc((size_t)size) : NULL;
        if (data && fread(data, 1, (size_t)size, file) == (size_t)size) {
            size_t position = 0, best = 0;
            // Each record holds three NUL-terminated UTF-8 paths. NUL cannot
            // occur in a filesystem path; bounded reads reject incomplete files.
            while (position < (size_t)size) {
                char *fields[3];
                int count = 0;
                for (; count < 3 && position < (size_t)size; count++) {
                    fields[count] = data + position;
                    size_t length = strnlen(fields[count], (size_t)size - position);
                    if (length == (size_t)size - position) break;
                    position += length + 1;
                }
                if (count != 3) break;
                size_t length = strlen(fields[0]);
                if (length > best && ((image && strcasestr(image, fields[0])) ||
                                      (archive && strcasestr(archive, fields[0])))) {
                    best = length;
                    setenv("CFProcessPath", fields[1], 1);
                    setenv("TRAVERSE_DOCK_ICON", fields[2], 1);
                }
            }
        }
        free(data);
        fclose(file);
    }
    const char *executable = image ? strrchr(image, '/') : NULL;
    executable = executable ? executable + 1 : image;
    const char *background[] = {"steam.exe", "explorer.exe", "services.exe", "winedevice.exe", "wineboot.exe"};
    for (size_t i = 0; executable && i < sizeof(background) / sizeof(background[0]); i++)
        if (!strcasecmp(executable, background[i])) background_process = 1;
    if (background_process) unsetenv("CFProcessPath");
    const char *keyboard_profile = getenv("TRAVERSE_DIRECT_KEYBOARD_PROFILE");
    const char *process_path = getenv("CFProcessPath");
    FILE *keyboard_file = keyboard_profile ? fopen(keyboard_profile, "rb") : NULL;
    if (keyboard_file && process_path && !background_process) {
        char *entry = NULL;
        size_t capacity = 0;
        ssize_t length;
        while ((length = getdelim(&entry, &capacity, 0, keyboard_file)) > 0) {
            if (entry[length - 1] == 0 && !strcmp(entry, process_path)) {
                direct_keyboard = 1;
                break;
            }
        }
        free(entry);
    }
    if (keyboard_file) fclose(keyboard_file);
    const char *icon = getenv("TRAVERSE_DOCK_ICON");
    if (icon) icon_path = strdup(icon);
    free(image);
    free(archive);

    // Set CFProcessPath before loading AppKit/Foundation: those frameworks cache
    // the main bundle during initialization, before Wine creates its windows.
    if (!dlopen("/System/Library/Frameworks/AppKit.framework/AppKit", RTLD_LAZY | RTLD_GLOBAL)) return;
    Class application = objc_getClass("NSApplication");
    Method method = class_getInstanceMethod(application, selector("setApplicationIconImage:"));
    original_set_icon = (void *)method_getImplementation(method);
    method_setImplementation(method, (IMP)set_application_icon);
    method = class_getInstanceMethod(application, selector("setActivationPolicy:"));
    original_set_policy = (void *)method_getImplementation(method);
    method_setImplementation(method, (IMP)set_activation_policy);
    method = class_getInstanceMethod(application, selector("finishLaunching"));
    original_finish_launching = (void *)method_getImplementation(method);
    method_setImplementation(method, (IMP)finish_launching);
    method = class_getInstanceMethod(application, selector("setMainMenu:"));
    original_set_main_menu = (void *)method_getImplementation(method);
    method_setImplementation(method, (IMP)set_main_menu);
}
