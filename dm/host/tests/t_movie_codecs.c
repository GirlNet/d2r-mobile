#include "../hle_movie_codecs.c"
#include "../guest_bootstrap.h"

typedef struct { void **vtable; int kind, deleted; } plugin_t;
static int registrations[3], null_registrations, deleting_calls, ordinary_calls;
static void *expected_master;
static int bad_master, checks, failures;
static void original_register(void *master, void *plugin) {
    bad_master |= master != expected_master;
    if (!plugin) { null_registrations++; return; }
    registrations[((plugin_t *)plugin)->kind]++;
}
static void ordinary_destructor(void *plugin) { (void)plugin; ordinary_calls++; }
static void deleting_destructor(void *plugin) {
    plugin_t *p = plugin; p->deleted++; deleting_calls++;
}
static void *nv_table[] = {NULL, NULL, (void *)ordinary_destructor, (void *)deleting_destructor};
static void *sw_table[] = {NULL, NULL, (void *)ordinary_destructor, (void *)deleting_destructor};
static void *other_table[] = {NULL, NULL, (void *)ordinary_destructor, (void *)deleting_destructor};
module_t g_mod[MAX_MOD]; int g_nmod = 2;
void *module_sym(module_t *module, const char *name) {
    if (module != &g_mod[1]) return NULL;
    if (!strcmp(name, ADD_PLUGIN)) return (void *)original_register;
    if (!strcmp(name, "_ZTVN7android11NVOMXPluginE")) return nv_table;
    if (!strcmp(name, "_ZTVN7android13SoftOMXPluginE")) return sw_table;
    return NULL;
}
static void check(int condition, const char *message) {
    checks++; failures += !condition;
    printf("%s %s\n", condition ? "PASS" : "FAIL", message);
}
int main(int argc, char **argv) {
    if (argc != 2 || !dm_guest_profile_select(argv[1])) return 2;
    int p5r = dm_guest_profile_p5r();
    int master = 7; expected_master = &master;
    plugin_t nv = {nv_table + 2, 0, 0}, sw = {sw_table + 2, 1, 0}, other = {other_table + 2, 2, 0};
    h_movie_add_plugin(&master, &nv);
    check(registrations[0] == !p5r, "NVIDIA registration follows the locked guest profile");
    check(nv.deleted == p5r && deleting_calls == p5r, "discarded NVIDIA plugin uses its deleting destructor exactly once");
    check(ordinary_calls == 0, "non-deleting destructor is never substituted for ownership release");
    h_movie_add_plugin(&master, &sw);
    check(registrations[1] == 1 && sw.deleted == 0, "real software plugin remains registered and owned by OMXMaster");
    h_movie_add_plugin(&master, &other);
    check(registrations[2] == 1 && other.deleted == 0, "unrelated plugins preserve the original registration path");
    h_movie_add_plugin(&master, NULL);
    check(null_registrations == 1, "null plugin preserves original SDK behavior");
    check(!bad_master, "original registrar receives the exact master object");
    check(!strcmp(hle_force_h_movie_add_plugin.name, ADD_PLUGIN) &&
          hle_force_h_movie_add_plugin.fn == (void *)h_movie_add_plugin,
          "exact SDK registrar symbol is forcibly resolved to the adapter");
    printf("MOVIE CODEC REGISTRATION %s: %d checks, %d failures\n", argv[1], checks, failures);
    return failures != 0;
}
