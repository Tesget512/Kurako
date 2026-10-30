#include "my_application.h"

#include <flutter_linux/flutter_linux.h>

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  GtkWindow* window;
  FlMethodChannel* oauth_callback_channel;
  gchar* pending_oauth_callback;
  gboolean awaiting_oauth;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

namespace {

constexpr char kOAuthCallbackChannel[] =
    "com.tesget.kurako/oauth_callback";

bool is_oauth_callback(const gchar* uri) {
  if (uri == nullptr) return false;
  g_autoptr(GError) error = nullptr;
  g_autoptr(GUri) parsed = g_uri_parse(uri, G_URI_FLAGS_NONE, &error);
  return parsed != nullptr && g_strcmp0(g_uri_get_scheme(parsed), "kurako") == 0 &&
         g_strcmp0(g_uri_get_host(parsed), "oauth") == 0 &&
         g_strcmp0(g_uri_get_path(parsed), "/callback") == 0;
}

void oauth_callback_response_cb(GObject* source, GAsyncResult* result,
                                gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  g_autoptr(GError) error = nullptr;
  g_autoptr(FlMethodResponse) response =
      fl_method_channel_invoke_method_finish(FL_METHOD_CHANNEL(source), result,
                                             &error);
  if (error == nullptr && response != nullptr &&
      FL_IS_METHOD_SUCCESS_RESPONSE(response)) {
    FlValue* value = fl_method_success_response_get_result(
        FL_METHOD_SUCCESS_RESPONSE(response));
    if (value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_BOOL &&
        fl_value_get_bool(value) && self->awaiting_oauth &&
        self->window != nullptr) {
      gtk_window_present(self->window);
    }
  }
  g_object_unref(self);
}

void dispatch_oauth_callback(MyApplication* self, const gchar* uri) {
  if (!is_oauth_callback(uri)) return;
  if (!self->awaiting_oauth || self->oauth_callback_channel == nullptr) {
    g_free(self->pending_oauth_callback);
    self->pending_oauth_callback = g_strdup(uri);
    return;
  }
  g_clear_pointer(&self->pending_oauth_callback, g_free);
  g_autoptr(FlValue) arguments = fl_value_new_string(uri);
  fl_method_channel_invoke_method(self->oauth_callback_channel,
                                  "onOAuthCallback", arguments, nullptr,
                                  oauth_callback_response_cb,
                                  g_object_ref(self));
}

void oauth_method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                          gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  const gchar* method = fl_method_call_get_name(method_call);
  if (g_strcmp0(method, "beginOAuth") == 0) {
    self->awaiting_oauth = TRUE;
    fl_method_call_respond_success(method_call, nullptr, nullptr);
    if (self->pending_oauth_callback != nullptr) {
      g_autofree gchar* pending =
          g_steal_pointer(&self->pending_oauth_callback);
      dispatch_oauth_callback(self, pending);
    }
    return;
  }
  if (g_strcmp0(method, "endOAuth") == 0) {
    self->awaiting_oauth = FALSE;
    g_clear_pointer(&self->pending_oauth_callback, g_free);
    fl_method_call_respond_success(method_call, nullptr, nullptr);
    return;
  }
  fl_method_call_respond_not_implemented(method_call, nullptr);
}

}  // namespace

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication*, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  if (self->window != nullptr) {
    gtk_window_present(self->window);
    return;
  }
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  self->window = window;

  // Flutter draws Kurako's cross-platform caption and window controls. Keep the
  // GTK window undecorated so Linux does not add a second title bar.
  gtk_window_set_decorated(window, FALSE);
  gtk_window_set_title(window, "Kurako");
  // Match the Dart window-manager defaults before its plugin becomes ready.
  // A 1440x900 start avoids the cramped WSLg/desktop first launch while the
  // 960x640 minimum keeps the navigation and player controls usable.
  gtk_window_set_default_size(window, 1440, 900);
  gtk_widget_set_size_request(GTK_WIDGET(window), 960, 640);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  // Flutter 3.47 enables Impeller on Linux by default. Its GLES backend has
  // asserted in BlitPassGLES on NVIDIA drivers at startup, so fall back to the
  // Skia renderer. KURAKO_IMPELLER=1 turns Impeller back on, and an explicit
  // --enable-impeller in FLUTTER_ENGINE_SWITCHES still takes precedence.
  const gchar* impeller_override = g_getenv("KURAKO_IMPELLER");
  fl_dart_project_set_enable_impeller(
      project, g_strcmp0(impeller_override, "1") == 0);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->oauth_callback_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      kOAuthCallbackChannel, FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      self->oauth_callback_channel, oauth_method_call_cb, self, nullptr);
  if (self->pending_oauth_callback != nullptr) {
    g_autofree gchar* pending = g_steal_pointer(&self->pending_oauth_callback);
    dispatch_oauth_callback(self, pending);
  }

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::open.
static void my_application_open(GApplication* application, GFile** files,
                                gint n_files, const gchar*) {
  MyApplication* self = MY_APPLICATION(application);
  if (self->window == nullptr) {
    g_application_activate(application);
  }
  for (gint i = 0; i < n_files; ++i) {
    g_autofree gchar* uri = g_file_get_uri(files[i]);
    dispatch_oauth_callback(self, uri);
  }
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_object(&self->oauth_callback_channel);
  g_clear_pointer(&self->pending_oauth_callback, g_free);
  self->awaiting_oauth = FALSE;
  self->window = nullptr;
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->open = my_application_open;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {
  self->window = nullptr;
  self->oauth_callback_channel = nullptr;
  self->pending_oauth_callback = nullptr;
  self->awaiting_oauth = FALSE;
}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_HANDLES_OPEN, nullptr));
}
