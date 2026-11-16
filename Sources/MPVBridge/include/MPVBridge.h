#pragma once
#include <stdint.h>
typedef struct tvmpv tvmpv;
// Handles remain resident: unloading a media library with Objective-C classes
// or a system Swift runtime dependency is unsafe.
int tvmpv_load(const char *path);
tvmpv *tvmpv_create(void);
int tvmpv_option(tvmpv *, const char *, const char *);
int tvmpv_headers(tvmpv *, const char *const *names, const char *const *values, int count);
int tvmpv_initialize(tvmpv *);
int tvmpv_command(tvmpv *, const char *const *);
int tvmpv_set_number(tvmpv *, const char *, double);
int tvmpv_set_flag(tvmpv *, const char *, int);
double tvmpv_number(tvmpv *, const char *, double fallback);
int tvmpv_flag(tvmpv *, const char *, int fallback);
int tvmpv_event(tvmpv *, int *error, int *reason);
int tvmpv_render_init(tvmpv *);
void tvmpv_render_callback(tvmpv *, void (*callback)(void *), void *);
void tvmpv_render(tvmpv *, int width, int height);
void tvmpv_render_free(tvmpv *);
void tvmpv_destroy(tvmpv *);
