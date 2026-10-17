// VI display/layer handles are opaque to the game. UIKit/CAMetalLayer owns
// presentation; the host NVN window retains only the native-window identity.
// Keep this entire lifecycle on the host instead of entering Horizon VI IPC.
#include "hle.h"
#include <pthread.h>
#define VI_HANDLES 64
typedef struct { unsigned layers; } vi_display;
typedef struct { vi_display *display; } vi_layer;
static pthread_mutex_t vi_lock=PTHREAD_MUTEX_INITIALIZER;
static unsigned vi_refs;
static vi_display *vi_displays[VI_HANDLES];
static vi_layer *vi_layers[VI_HANDLES];
static int vi_display_index(const void *handle) { for(int i=0;i<VI_HANDLES;i++)if(handle&&vi_displays[i]==handle)return i;return -1; }
static int vi_layer_index(const void *handle) { for(int i=0;i<VI_HANDLES;i++)if(handle&&vi_layers[i]==handle)return i;return -1; }

HLE_FORCE_OPTIONAL("_ZN2nn2vi10InitializeEv", "UIKit owns display presentation; initialize host opaque VI handles without service IPC", void, h_vi_Initialize, void) {
    pthread_mutex_lock(&vi_lock);if(vi_refs==UINT32_MAX)die("VI initialization count overflow");vi_refs++;pthread_mutex_unlock(&vi_lock);
}
HLE_FORCE_OPTIONAL("_ZN2nn2vi18OpenDefaultDisplayEPPNS0_7DisplayE", "Open a host display identity without connecting to vi:u", Result, h_vi_OpenDefaultDisplay, void **output) {
    if(!output)return RES_FAIL;
    pthread_mutex_lock(&vi_lock);int slot=-1;
    if(vi_refs)for(int i=0;i<VI_HANDLES;i++)if(!vi_displays[i]){slot=i;break;}
    vi_display *display=slot<0?NULL:calloc(1,sizeof *display);
    if(display){vi_displays[slot]=display;*output=display;}
    pthread_mutex_unlock(&vi_lock);return display?RES_OK:RES_FAIL;
}
HLE_FORCE_OPTIONAL("_ZN2nn2vi11CreateLayerEPPNS0_5LayerEPNS0_7DisplayE", "Create a host layer identity consumed by the host NVN window", Result, h_vi_CreateLayer, void **output, void *display) {
    if(!output)return RES_FAIL;
    pthread_mutex_lock(&vi_lock);int slot=-1,owner=vi_display_index(display);
    if(vi_refs&&owner>=0)for(int i=0;i<VI_HANDLES;i++)if(!vi_layers[i]){slot=i;break;}
    vi_layer *layer=slot<0?NULL:calloc(1,sizeof *layer);
    if(layer){layer->display=vi_displays[owner];layer->display->layers++;vi_layers[slot]=layer;*output=layer;}
    pthread_mutex_unlock(&vi_lock);return layer?RES_OK:RES_FAIL;
}
HLE_FORCE_OPTIONAL("_ZN2nn2vi15GetNativeWindowEPPvPNS0_5LayerE", "Return the stable host layer identity; NVN presents through the front-end CAMetalLayer", Result, h_vi_GetNativeWindow, void **output, void *layer) {
    if(!output)return RES_FAIL;
    pthread_mutex_lock(&vi_lock);int slot=vi_layer_index(layer);
    if(slot>=0)*output=vi_layers[slot];pthread_mutex_unlock(&vi_lock);return slot>=0?RES_OK:RES_FAIL;
}
HLE_FORCE_OPTIONAL("_ZN2nn2vi12DestroyLayerEPNS0_5LayerE", "Destroy host layer state without SDK buffer-queue destruction", void, h_vi_DestroyLayer, void *handle) {
    pthread_mutex_lock(&vi_lock);int slot=vi_layer_index(handle);if(slot<0)die("Invalid VI layer destruction");
    vi_layer *layer=vi_layers[slot];layer->display->layers--;vi_layers[slot]=NULL;free(layer);pthread_mutex_unlock(&vi_lock);
}
HLE_FORCE_OPTIONAL("_ZN2nn2vi12CloseDisplayEPNS0_7DisplayE", "Close an empty host display without Horizon VI IPC", void, h_vi_CloseDisplay, void *handle) {
    pthread_mutex_lock(&vi_lock);int slot=vi_display_index(handle);if(slot<0||vi_displays[slot]->layers)die("Invalid VI display close or live layers");
    free(vi_displays[slot]);vi_displays[slot]=NULL;pthread_mutex_unlock(&vi_lock);
}
HLE_FORCE_OPTIONAL("_ZN2nn2vi8FinalizeEv", "Finalize host-only VI state after all displays and layers close", void, h_vi_Finalize, void) {
    pthread_mutex_lock(&vi_lock);
    if(vi_refs==1)for(int i=0;i<VI_HANDLES;i++)if(vi_displays[i]||vi_layers[i])die("VI finalization with live host handles");
    if(vi_refs)vi_refs--;pthread_mutex_unlock(&vi_lock);
}
