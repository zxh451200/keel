#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#include <sys/stat.h>
#include <cstring>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"
#include "print_report.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Owned by the window, and detached before its Flutter engine is destroyed.
struct DesktopFiles {
  GtkWindow* window;
  FlMethodChannel* channel;
  GtkFileChooserNative* chooser;
  GtkPrintOperation* print_operation;  // Borrowed during synchronous run.
  FlMethodCall* pending;
  bool destroyed;
  bool busy;
  bool save;
};

static void desktop_files_error(FlMethodCall* call) {
  if (g_strcmp0(fl_method_call_get_name(call), "printReport") == 0) {
    fl_method_call_respond_error(call, "KEEL-PRINT", "", nullptr, nullptr);
    return;
  }
  const bool save =
      g_strcmp0(fl_method_call_get_name(call), "chooseAuditCsvSavePath") == 0;
  fl_method_call_respond_error(call, "KEEL-IO", save ? "" : nullptr, nullptr,
                               nullptr);
}

static bool desktop_files_csv_name(const gchar* name) {
  if (!name || !g_utf8_validate(name, -1, nullptr) ||
      std::strlen(name) <= 4 || !g_str_has_suffix(name, ".csv")) return false;
  for (const gchar* p = name; *p; p = g_utf8_next_char(p)) {
    const gunichar c = g_utf8_get_char(p);
    if (c == '/' || c == '\\' || g_unichar_iscntrl(c)) return false;
  }
  return true;
}

static void desktop_files_clear_chooser(DesktopFiles* files) {
  if (files->chooser) {
    // Detach before destroy, which can synchronously emit GTK signals.
    GtkFileChooserNative* chooser = files->chooser;
    files->chooser = nullptr;
    g_signal_handlers_disconnect_by_data(chooser, files);
    gtk_native_dialog_destroy(GTK_NATIVE_DIALOG(chooser));
    g_object_unref(chooser);
  }
}

static void desktop_files_response(GtkNativeDialog*, gint response,
                                   gpointer user_data) {
  auto* files = static_cast<DesktopFiles*>(user_data);
  if (!files->pending) return;
  // Native-dialog cleanup can emit signals that destroy the owner. Keep its
  // attached state allocated until this callback has sent its sole response.
  g_autoptr(GtkWindow) owner = GTK_WINDOW(g_object_ref(files->window));
  // Steal the response before destroying the native dialog: only one reply.
  g_autoptr(FlMethodCall) call = files->pending;
  files->pending = nullptr;
  g_autofree gchar* path = nullptr;
  bool failed = false;
  if (response == GTK_RESPONSE_ACCEPT) {
    g_autoptr(GFile) file =
        gtk_file_chooser_get_file(GTK_FILE_CHOOSER(files->chooser));
    if (file && g_file_is_native(file)) path = g_file_get_path(file);
    failed = !path || !g_path_is_absolute(path);
    if (!failed && files->save) {
      // GTK has no default-extension API. Supply .csv only when omitted.
      // This chooses a path only: Rust must reject existing files at write time,
      // even after GTK's ordinary overwrite confirmation.
      g_autofree gchar* basename = g_path_get_basename(path);
      if (!std::strchr(basename, '.')) {
        gchar* extended = g_strconcat(path, ".csv", nullptr);
        g_free(path);
        path = extended;
        g_free(basename);
        basename = g_path_get_basename(path);
      }
      failed = !desktop_files_csv_name(basename);
    } else if (!failed) {
      struct stat metadata;
      // Preserve open's rejection of symlinks and special files.
      failed = lstat(path, &metadata) != 0 || !S_ISREG(metadata.st_mode);
    }
  } else if (response != GTK_RESPONSE_CANCEL &&
             response != GTK_RESPONSE_DELETE_EVENT &&
             response != GTK_RESPONSE_CLOSE) {
    failed = true;
  }
  desktop_files_clear_chooser(files);
  if (failed || files->destroyed) {
    desktop_files_error(call);
  } else if (path) {
    // Preserve the exact filesystem path. Non-UTF-8 Unix filenames cannot be
    // represented by this String contract; do not transcode into another path.
    if (!g_utf8_validate(path, -1, nullptr)) {
      desktop_files_error(call);
      files->busy = false;
      return;
    }
    g_autoptr(FlValue) value = fl_value_new_string(path);
    fl_method_call_respond_success(call, value, nullptr);
  } else {
    fl_method_call_respond_success(call, nullptr, nullptr);
  }
  files->busy = false;
}

static const gchar* desktop_files_label(FlValue* args, const gchar* key) {
  if (!args || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) return nullptr;
  FlValue* value = fl_value_lookup_string(args, key);
  if (!value || fl_value_get_type(value) != FL_VALUE_TYPE_STRING) return nullptr;
  const gchar* text = fl_value_get_string(value);
  return text && *text && g_utf8_validate(text, -1, nullptr) ? text : nullptr;
}

static void desktop_files_method(FlMethodChannel*, FlMethodCall* call,
                                 gpointer user_data) {
  auto* files = static_cast<DesktopFiles*>(user_data);
  if (g_strcmp0(fl_method_call_get_name(call), "printReport") == 0) {
    FlValue* args = fl_method_call_get_args(call);
    const gchar* title = desktop_files_label(args, "title");
    const gchar* content = desktop_files_label(args, "content");
    if (files->destroyed || files->busy || !title || !content) {
      desktop_files_error(call);
      return;
    }
    // The codec validates original byte lengths, UTF-8 and NULs. Keep the
    // owner/state alive across GTK's reentrant dialog loop.
    g_autoptr(GtkWindow) owner = GTK_WINDOW(g_object_ref(files->window));
    g_autoptr(GtkPrintOperation) operation = gtk_print_operation_new();
    files->busy = true;
    files->pending = FL_METHOD_CALL(g_object_ref(call));
    files->print_operation = operation;
    const GtkPrintOperationResult result =
        keel_print_report_run(operation, owner, title, content);
    files->print_operation = nullptr;
    // destroy() consumes pending before detaching the messenger.
    g_autoptr(FlMethodCall) pending = files->pending;
    files->pending = nullptr;
    if (pending && !files->destroyed) {
      if (result == GTK_PRINT_OPERATION_RESULT_APPLY ||
          result == GTK_PRINT_OPERATION_RESULT_CANCEL) {
        g_autoptr(FlValue) value = fl_value_new_string(
            result == GTK_PRINT_OPERATION_RESULT_APPLY ? "printed" : "cancelled");
        fl_method_call_respond_success(pending, value, nullptr);
      } else {
        desktop_files_error(pending);
      }
    }
    files->busy = false;
    return;
  }
  const bool save =
      g_strcmp0(fl_method_call_get_name(call), "chooseAuditCsvSavePath") == 0;
  const bool diagnostic =
      g_strcmp0(fl_method_call_get_name(call), "selectExternalDiagnosticFile") == 0;
  if (!save && !diagnostic &&
      g_strcmp0(fl_method_call_get_name(call), "selectConfigFile") != 0) {
    fl_method_call_respond_not_implemented(call, nullptr);
    return;
  }
  FlValue* args = fl_method_call_get_args(call);
  const gchar* title = desktop_files_label(args, "title");
  const gchar* filter_label = desktop_files_label(args, "filterLabel");
  const gchar* cancel_label = desktop_files_label(args, "cancelLabel");
  const gchar* open_label =
      desktop_files_label(args, save ? "saveLabel" : "openLabel");
  const gchar* suggested_name = desktop_files_label(args, "suggestedName");
  if (files->destroyed || files->busy || !title || !filter_label ||
      !cancel_label || !open_label ||
      (save && !desktop_files_csv_name(suggested_name))) {
    desktop_files_error(call);
    return;
  }
  files->busy = true;
  files->save = save;
  files->pending = FL_METHOD_CALL(g_object_ref(call));
  files->chooser = gtk_file_chooser_native_new(
      title, files->window,
      save ? GTK_FILE_CHOOSER_ACTION_SAVE : GTK_FILE_CHOOSER_ACTION_OPEN,
      open_label, cancel_label);
  if (!files->chooser) {
    desktop_files_error(files->pending);
    g_clear_object(&files->pending);
    files->busy = false;
    return;
  }
  GtkFileChooser* chooser = GTK_FILE_CHOOSER(files->chooser);
  gtk_file_chooser_set_local_only(chooser, TRUE);
  gtk_file_chooser_set_select_multiple(chooser, FALSE);
  if (save) {
    gtk_file_chooser_set_current_name(chooser, suggested_name);
    gtk_file_chooser_set_create_folders(chooser, FALSE);
    gtk_file_chooser_set_do_overwrite_confirmation(chooser, TRUE);
  }
  // Filters are only a hint; Rust validates the selected path at use.
  GtkFileFilter* filter = gtk_file_filter_new();
  gtk_file_filter_set_name(filter, filter_label);
  gtk_file_filter_add_pattern(filter, save ? "*.csv" : "*.json");
  if (diagnostic) {
    gtk_file_filter_add_pattern(filter, "*.txt");
    gtk_file_filter_add_pattern(filter, "*.log");
    gtk_file_filter_add_pattern(filter, "*.jsonl");
  }
  gtk_file_chooser_add_filter(chooser, filter);  // Takes the floating reference.
  gtk_file_chooser_set_filter(chooser, filter);
  gtk_native_dialog_set_modal(GTK_NATIVE_DIALOG(files->chooser), TRUE);
  g_signal_connect(files->chooser, "response",
                   G_CALLBACK(desktop_files_response), files);
  gtk_native_dialog_show(GTK_NATIVE_DIALOG(files->chooser));
}

static void desktop_files_destroy(GtkWidget*, gpointer user_data) {
  auto* files = static_cast<DesktopFiles*>(user_data);
  if (files->destroyed) return;
  files->destroyed = true;
  // Reply while the engine/messenger still belongs to the window.
  g_autoptr(FlMethodCall) pending = files->pending;
  files->pending = nullptr;
  if (pending) desktop_files_error(pending);
  desktop_files_clear_chooser(files);
  if (files->print_operation)
    keel_print_report_cancel(files->print_operation, files->window);
  fl_method_channel_set_method_call_handler(files->channel, nullptr, nullptr,
                                            nullptr);
  g_clear_object(&files->channel);
}

static void desktop_files_attach(GtkWindow* window, FlView* view) {
  auto* files = g_new0(DesktopFiles, 1);
  files->window = window;
  g_autoptr(FlMethodCodec) codec = keel_desktop_files_codec_new();
  files->channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "keel/desktop_files", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      files->channel, desktop_files_method, files, nullptr);
  g_object_set_data_full(G_OBJECT(window), "keel-desktop-files", files, g_free);
  g_signal_connect(window, "destroy", G_CALLBACK(desktop_files_destroy), files);
}

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "keel");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "keel");
  }

  gtk_window_set_default_size(window, 1280, 720);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

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
  desktop_files_attach(window, view);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GtkApplication::window_removed.
static void my_application_window_removed(GtkApplication* application,
                                          GtkWindow* window) {
  // Flutter detaches the window before quitting. Cancel before shutdown,
  // which cannot run until synchronous GTK dialog loops have unwound.
  // Retain the window; do not destroy the engine inside its exit callback.
  g_autoptr(GtkWindow) owner = GTK_WINDOW(g_object_ref(window));
  auto* files = static_cast<DesktopFiles*>(
      g_object_get_data(G_OBJECT(owner), "keel-desktop-files"));
  if (files) desktop_files_destroy(GTK_WIDGET(owner), files);
  GTK_APPLICATION_CLASS(my_application_parent_class)->window_removed(
      application, owner);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // Fallback for windows still registered after early window_removed cleanup.
  GList* windows = g_list_copy(gtk_application_get_windows(GTK_APPLICATION(application)));
  for (GList* item = windows; item; item = item->next) g_object_ref(item->data);
  for (GList* item = windows; item; item = item->next) {
    if (g_object_get_data(G_OBJECT(item->data), "keel-desktop-files"))
      gtk_widget_destroy(GTK_WIDGET(item->data));
  }
  g_list_free_full(windows, g_object_unref);

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  GTK_APPLICATION_CLASS(klass)->window_removed = my_application_window_removed;
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
