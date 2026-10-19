// Keep the SDK's real software movie codecs on hosts without Horizon nvdrv.
// OMXMaster constructs both NVOMXPlugin and SoftOMXPlugin. Registering the NV
// plugin lets capability probes or playback enter /dev/nvhost-ctrl and abort
// in NvOsDrvOpen's InitCheck. Retire that plugin before it is registered;
// the original software plugin, codec selection, decode and output stay active.
#include "hle.h"

#define ADD_PLUGIN "_ZN7android9OMXMaster9addPluginEPNS_13OMXPluginBaseE"
typedef void (*add_plugin_fn)(void *, void *);
static add_plugin_fn original_add_plugin;
static void **nv_plugin_vtable, **software_plugin_vtable;
static pthread_once_t codec_symbols_once = PTHREAD_ONCE_INIT;

static void *movie_raw_symbol(const char *name) {
    for (int i = 0; i < g_nmod; i++) {
        void *p = module_sym(&g_mod[i], name);
        if (p) return p;
    }
    return NULL;
}
static void movie_codec_symbols(void) {
    original_add_plugin = (add_plugin_fn)movie_raw_symbol(ADD_PLUGIN);
    if (!original_add_plugin) die("movie: original OMX plugin registrar is missing");
    if (!dm_guest_d2r()) {
        void **nv = movie_raw_symbol("_ZTVN7android11NVOMXPluginE");
        void **sw = movie_raw_symbol("_ZTVN7android13SoftOMXPluginE");
        if (!nv || !sw) die("movie: SDK hardware/software plugin vtables are missing");
        // Itanium C++ ABI: offset-to-top and RTTI precede the address point.
        nv_plugin_vtable = nv + 2;
        software_plugin_vtable = sw + 2;
    }
}
HLE_FORCE_OPTIONAL("_ZN7android9OMXMaster9addPluginEPNS_13OMXPluginBaseE", "P5R retains SDK software movie codecs; Horizon NVIDIA plugin cannot run on the host", void, h_movie_add_plugin, void *master, void *plugin) {
    pthread_once(&codec_symbols_once, movie_codec_symbols);
    void **vtable = plugin ? *(void ***)plugin : NULL;
    if (!dm_guest_d2r() && vtable == nv_plugin_vtable && plugin) {
        // addPlugin takes ownership. D0, the second virtual destructor entry,
        // releases the initialized plugin and its original guest allocation.
        if (!vtable[1]) die("movie: SDK NVIDIA plugin deleting destructor is missing");
        LOG("P5R movie: retiring Horizon NVIDIA OMX plugin; keeping SDK software decoding");
        ((void (*)(void *))vtable[1])(plugin);
        return;
    }
    original_add_plugin(master, plugin);
    if (!dm_guest_d2r() && plugin && vtable == software_plugin_vtable)
        LOG("P5R movie: SDK software OMX plugin registered");
}
