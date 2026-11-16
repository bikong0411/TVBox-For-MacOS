// mpv public ABI subset. API structure declarations follow the ISC-licensed
// libmpv headers; see MPV-API-LICENSE.txt. No media library is linked or bundled.
#include "MPVBridge.h"
#include <dlfcn.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <OpenGL/gl3.h>

typedef struct mpv_node mpv_node;
typedef struct { int num; mpv_node *values; char **keys; } node_list;
struct mpv_node { union { char *string; int flag; int64_t int64; double double_; node_list *list; void *ba; } u; int format; };
typedef struct { int id, error; uint64_t userdata; void *data; } event;
typedef struct { int type; void *data; } render_param;
typedef struct { void *(*get_proc)(void *, const char *); void *context; } gl_init;
typedef struct { int fbo, width, height, format; } gl_fbo;

static void *library;
static void *(*create_)(void);
static int (*init_)(void *);
static int (*opt_)(void *, const char *, const char *);
static int (*option_)(void *, const char *, int, void *);
static int (*get_)(void *, const char *, int, void *);
static int (*set_)(void *, const char *, int, void *);
static int (*command_)(void *, uint64_t, const char **);
static event *(*event_)(void *, double);
static void (*destroy_)(void *);
static int (*render_init_)(void **, void *, render_param *);
static int (*render_)(void *, render_param *);
static uint64_t (*update_)(void *);
static void (*render_cb_)(void *, void (*)(void *), void *);
static void (*render_free_)(void *);
struct tvmpv { void *core, *renderer; };

int tvmpv_load(const char *path) {
    if (library) return 0;
    void *handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!handle) return -1;
#define LOAD(var, name) do { *(void **)(&var) = dlsym(handle, name); if (!var) return -2; } while (0)
    unsigned long (*version)(void); LOAD(version, "mpv_client_api_version");
    if ((version() >> 16) != 2) return -3;
    LOAD(create_, "mpv_create"); LOAD(init_, "mpv_initialize");
    LOAD(opt_, "mpv_set_option_string"); LOAD(option_, "mpv_set_option");
    LOAD(get_, "mpv_get_property"); LOAD(set_, "mpv_set_property");
    LOAD(command_, "mpv_command_async"); LOAD(event_, "mpv_wait_event");
    LOAD(destroy_, "mpv_terminate_destroy");
    LOAD(render_init_, "mpv_render_context_create"); LOAD(render_, "mpv_render_context_render");
    LOAD(update_, "mpv_render_context_update"); LOAD(render_cb_, "mpv_render_context_set_update_callback");
    LOAD(render_free_, "mpv_render_context_free");
#undef LOAD
    library = handle; return 0;
}
tvmpv *tvmpv_create(void) {
    if (!library) return NULL;
    tvmpv *m = calloc(1, sizeof(*m)); if (!m) return NULL;
    m->core = create_(); if (!m->core) { free(m); return NULL; } return m;
}
int tvmpv_option(tvmpv *m, const char *key, const char *value) { return opt_(m->core, key, value); }
int tvmpv_headers(tvmpv *m, const char *const *names, const char *const *values, int count) {
    mpv_node *nodes = calloc(count, sizeof(*nodes));
    if (count && !nodes) return -1;
    for (int i = 0; i < count; i++) {
        size_t size = strlen(names[i]) + strlen(values[i]) + 3;
        nodes[i].u.string = malloc(size); nodes[i].format = 1;
        if (!nodes[i].u.string) { for (int j=0;j<i;j++) free(nodes[j].u.string); free(nodes); return -1; }
        snprintf(nodes[i].u.string, size, "%s: %s", names[i], values[i]);
    }
    node_list list = {count, nodes, NULL}; mpv_node node = {.u.list = &list, .format = 7};
    int result = option_(m->core, "http-header-fields", 6, &node);
    for (int i=0;i<count;i++) free(nodes[i].u.string); free(nodes); return result;
}
int tvmpv_initialize(tvmpv *m) { return init_(m->core); }
int tvmpv_command(tvmpv *m, const char *const *args) { return command_(m->core, 0, (const char **)args); }
int tvmpv_set_number(tvmpv *m, const char *key, double v) { return set_(m->core, key, 5, &v); }
int tvmpv_set_flag(tvmpv *m, const char *key, int v) { return set_(m->core, key, 3, &v); }
double tvmpv_number(tvmpv *m, const char *key, double fallback) { double v; return get_(m->core, key, 5, &v) < 0 ? fallback : v; }
int tvmpv_flag(tvmpv *m, const char *key, int fallback) { int v; return get_(m->core, key, 3, &v) < 0 ? fallback : v; }
int tvmpv_event(tvmpv *m, int *error, int *reason) {
    event *e = event_(m->core, 0); *error = e->error; *reason = -1;
    if (e->id == 7 && e->data) { int *end = e->data; *reason = end[0]; *error = end[1]; }
    return e->id;
}
static void *gl_symbol(void *ctx, const char *name) { return dlsym(ctx, name); }
int tvmpv_render_init(tvmpv *m) {
    static void *gl; if (!gl) gl = dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL", RTLD_LAZY | RTLD_LOCAL);
    gl_init init = {gl_symbol, gl};
    render_param p[] = {{1, "opengl"}, {2, &init}, {0, NULL}};
    return render_init_(&m->renderer, m->core, p);
}
void tvmpv_render_callback(tvmpv *m, void (*cb)(void *), void *ctx) { if (m->renderer) render_cb_(m->renderer, cb, ctx); }
void tvmpv_render(tvmpv *m, int width, int height) {
    if (!m->renderer || width < 1 || height < 1) return;
    gl_fbo fbo = {0, width, height, 0}; int flip = 1, block = 0;
    render_param p[] = {{3, &fbo}, {4, &flip}, {12, &block}, {0, NULL}};
    update_(m->renderer); render_(m->renderer, p);
}
void tvmpv_render_free(tvmpv *m) {
    if (m->renderer) { render_cb_(m->renderer, NULL, NULL); render_free_(m->renderer); m->renderer = NULL; }
}
void tvmpv_destroy(tvmpv *m) { if (m) { destroy_(m->core); free(m); } }
