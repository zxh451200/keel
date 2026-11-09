#include "print_report.h"

#include <pango/pangocairo.h>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <string>
#include <utility>
#include <vector>

namespace {
constexpr gsize kMaxText = 1024 * 1024;

bool valid_report_text(const char* text, bool body) {
  if (!text || !*text || std::strlen(text) > kMaxText ||
      !g_utf8_validate(text, -1, nullptr)) return false;
  for (const char* cursor = text; *cursor; cursor = g_utf8_next_char(cursor)) {
    const gunichar c = g_utf8_get_char(cursor);
    const bool allowed = body && (c == 9 || c == 10 || c == 13);
    if ((c < 32 && !allowed) || (c >= 0x7f && c <= 0x9f) ||
        c == 0x2028 || c == 0x2029) return false;
    if (c == 13 || c == 10) {
      if (c == 13 && cursor[1] == '\n') ++cursor;
    }
  }
  return true;
}

// Only the print contract is parsed here. Other methods retain GTK runner's
// standard codec behavior. Bounds precede every access/allocation.
struct WireReader {
  const guint8* data;
  gsize size;
  gsize offset = 0;

  bool byte(guint8 expected) {
    return offset < size && data[offset++] == expected;
  }
  bool length(guint32* value) {
    if (offset >= size) return false;
    guint8 first = data[offset++];
    if (first < 254) { *value = first; return true; }
    const gsize count = first == 254 ? 2 : 4;
    if (size - offset < count) return false;
    // StandardMessageCodec writes multi-byte size markers in big-endian order.
    // Do not decode them as host-endian values: the codec contract is
    // independent of the runner CPU architecture.
    if (count == 2) {
      guint16 short_value;
      std::memcpy(&short_value, data + offset, count);
      *value = GUINT16_FROM_BE(short_value);
    } else {
      std::memcpy(value, data + offset, count);
      *value = GUINT32_FROM_BE(*value);
    }
    offset += count;
    return true;
  }
  bool text(std::string* value, gsize limit) {
    guint32 count;
    if (!byte(7) || !length(&count) || count > limit ||
        count > size - offset) return false;
    const char* start = reinterpret_cast<const char*>(data + offset);
    if (std::memchr(start, 0, count) ||
        !g_utf8_validate(start, count, nullptr)) return false;
    value->assign(start, count);
    offset += count;
    return true;
  }
};

typedef struct { FlMethodCodec parent; } KeelPrintCodec;
typedef struct { FlMethodCodecClass parent; } KeelPrintCodecClass;
G_DEFINE_TYPE(KeelPrintCodec, keel_print_codec, fl_method_codec_get_type())

gboolean decode_call(FlMethodCodec*, GBytes* message, gchar** name,
                     FlValue** args, GError** error) {
  gsize size;
  const auto* data = static_cast<const guint8*>(g_bytes_get_data(message, &size));
  WireReader reader{data, size};
  std::string method;
  if (!reader.text(&method, 128) || method != "printReport") {
    g_autoptr(FlStandardMethodCodec) standard = fl_standard_method_codec_new();
    g_autofree gchar* decoded_name = nullptr;
    g_autoptr(FlValue) decoded_args = nullptr;
    const gboolean decoded = FL_METHOD_CODEC_GET_CLASS(standard)->decode_method_call(
        FL_METHOD_CODEC(standard), message, &decoded_name, &decoded_args, error);
    if (!decoded) return FALSE;
    // A malformed method name containing NUL can become "printReport" after
    // standard decoding. It must never bypass the original-byte validator.
    if (g_strcmp0(decoded_name, "printReport") == 0) {
      g_clear_pointer(&decoded_args, fl_value_unref);
      decoded_args = fl_value_new_null();
    }
    if (name) *name = g_steal_pointer(&decoded_name);
    if (args) *args = g_steal_pointer(&decoded_args);
    return TRUE;
  }
  std::string title, content;
  bool title_seen = false, content_seen = false;
  guint32 count;
  bool valid = reader.byte(13) && reader.length(&count) && count == 2;
  for (guint32 i = 0; valid && i < count; ++i) {
    std::string key, value;
    valid = reader.text(&key, 7) && reader.text(&value, kMaxText) && !value.empty();
    if (!valid) break;
    if (key == "title" && !title_seen) {
      title_seen = true;
      title = std::move(value);
    } else if (key == "content" && !content_seen) {
      content_seen = true;
      content = std::move(value);
    } else {
      valid = false;
    }
  }
  valid = valid && title_seen && content_seen && reader.offset == size;
  valid = valid && valid_report_text(title.c_str(), false) &&
      valid_report_text(content.c_str(), true);
  if (name) *name = g_strdup("printReport");
  if (args) {
    *args = valid ? fl_value_new_map() : fl_value_new_null();
    if (valid) {
      fl_value_set_string_take(*args, "title", fl_value_new_string(title.c_str()));
      fl_value_set_string_take(*args, "content", fl_value_new_string(content.c_str()));
    }
  }
  return TRUE;
}

GBytes* encode_call(FlMethodCodec*, const gchar* name, FlValue* args, GError** error) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  return FL_METHOD_CODEC_GET_CLASS(codec)->encode_method_call(
      FL_METHOD_CODEC(codec), name, args, error);
}
GBytes* encode_success(FlMethodCodec*, FlValue* value, GError** error) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  return FL_METHOD_CODEC_GET_CLASS(codec)->encode_success_envelope(
      FL_METHOD_CODEC(codec), value, error);
}
GBytes* encode_error(FlMethodCodec*, const gchar* code, const gchar* message,
                     FlValue* details, GError** error) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  return FL_METHOD_CODEC_GET_CLASS(codec)->encode_error_envelope(
      FL_METHOD_CODEC(codec), code, message, details, error);
}
FlMethodResponse* decode_response(FlMethodCodec*, GBytes* bytes, GError** error) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  return FL_METHOD_CODEC_GET_CLASS(codec)->decode_response(
      FL_METHOD_CODEC(codec), bytes, error);
}
void keel_print_codec_class_init(KeelPrintCodecClass* klass) {
  auto* codec = FL_METHOD_CODEC_CLASS(klass);
  codec->decode_method_call = decode_call;
  codec->encode_method_call = encode_call;
  codec->encode_success_envelope = encode_success;
  codec->encode_error_envelope = encode_error;
  codec->decode_response = decode_response;
}
void keel_print_codec_init(KeelPrintCodec*) {}

struct DrawLine {
  gsize paragraph;
  int length;
  int index;
  double y, scale, left, top;
};
struct Report {
  std::string text;
  std::vector<std::vector<DrawLine>> pages;
  PangoLayout* layout = nullptr;
  gsize layout_paragraph = std::numeric_limits<gsize>::max();
  std::vector<PangoLayoutLine*> layout_lines;
  bool failed = false;
  bool preview = false;
  ~Report() { g_clear_object(&layout); }
};

void fail_report(GtkPrintOperation* operation, Report* report) {
  report->failed = true;
  gtk_print_operation_cancel(operation);
}

void begin_print(GtkPrintOperation* operation, GtkPrintContext* context,
                 gpointer data) {
  auto* report = static_cast<Report*>(data);
  const double width = gtk_print_context_get_width(context);
  const double height = gtk_print_context_get_height(context);
  if (!std::isfinite(width) || !std::isfinite(height) || width <= 0 ||
      height <= 0 || width > G_MAXINT / PANGO_SCALE) {
    fail_report(operation, report);
    return;
  }
  report->layout = gtk_print_context_create_pango_layout(context);
  PangoFontDescription* font = pango_font_description_from_string("Sans 10");
  pango_layout_set_font_description(report->layout, font);
  pango_font_description_free(font);
  pango_layout_set_width(report->layout, static_cast<int>(width * PANGO_SCALE));
  pango_layout_set_wrap(report->layout, PANGO_WRAP_WORD_CHAR);
  pango_layout_set_ellipsize(report->layout, PANGO_ELLIPSIZE_NONE);
  report->pages.emplace_back();
  double y = 0;
  gsize start = 0;
  // Lay out each logical paragraph separately: a MiB of newlines must not
  // overflow Pango's signed, fixed-point total layout height.
  do {
    const gsize end = report->text.find('\n', start);
    const gsize length = (end == std::string::npos ? report->text.size() : end) - start;
    pango_layout_set_text(report->layout, report->text.data() + start,
                          static_cast<int>(length));
    int index = 0;
    for (GSList* item = pango_layout_get_lines_readonly(report->layout);
         item; item = item->next, ++index) {
      auto* line = static_cast<PangoLayoutLine*>(item->data);
      PangoRectangle ink, logical;
      pango_layout_line_get_extents(line, &ink, &logical);
      const double left = std::min(ink.x, logical.x) / double(PANGO_SCALE);
      const double top = std::min(ink.y, logical.y) / double(PANGO_SCALE);
      const double right = std::max(double(ink.x) + ink.width,
                                    double(logical.x) + logical.width) / PANGO_SCALE;
      const double bottom = std::max(double(ink.y) + ink.height,
                                     double(logical.y) + logical.height) / PANGO_SCALE;
      const double line_height = std::max(1.0, bottom - top);
      // An indivisible Unicode cluster may exceed even a whole page. Scale
      // that visual line to fit, rather than clipping or dropping its glyphs.
      const double scale = std::min({1.0, width / std::max(1.0, right - left),
                                     height / line_height});
      const double advance = line_height * scale;
      if (y > 0 && y + advance > height) {
        report->pages.emplace_back();
        y = 0;
      }
      if (length != 0) {
        report->pages.back().push_back(
            {start, static_cast<int>(length), index, y, scale, left, top});
      }
      y += advance;  // Empty lines consume space too, including trailing ones.
    }
    if (end == std::string::npos) break;
    start = end + 1;
  } while (start <= report->text.size());
  if (report->pages.size() > static_cast<gsize>(G_MAXINT)) {
    fail_report(operation, report);
    return;
  }
  gtk_print_operation_set_n_pages(operation, static_cast<int>(report->pages.size()));
}

void draw_page(GtkPrintOperation* operation, GtkPrintContext* context,
               gint page, gpointer data) {
  auto* report = static_cast<Report*>(data);
  if (page < 0 || static_cast<gsize>(page) >= report->pages.size()) {
    fail_report(operation, report);
    return;
  }
  cairo_t* cr = gtk_print_context_get_cairo_context(context);
  for (const DrawLine& item : report->pages[page]) {
    if (report->layout_paragraph != item.paragraph) {
      pango_layout_set_text(report->layout, report->text.data() + item.paragraph,
                            item.length);
      report->layout_paragraph = item.paragraph;
      report->layout_lines.clear();
      for (GSList* entry = pango_layout_get_lines_readonly(report->layout);
           entry; entry = entry->next)
        report->layout_lines.push_back(static_cast<PangoLayoutLine*>(entry->data));
    }
    if (item.index < 0 || static_cast<gsize>(item.index) >= report->layout_lines.size()) {
      fail_report(operation, report);
      return;
    }
    PangoLayoutLine* line = report->layout_lines[item.index];
    if (!line) { fail_report(operation, report); return; }
    cairo_save(cr);
    cairo_set_source_rgb(cr, 0, 0, 0);
    cairo_translate(cr, 0, item.y);
    cairo_scale(cr, item.scale, item.scale);
    cairo_move_to(cr, -item.left, -item.top);
    pango_cairo_show_layout_line(cr, line);
    cairo_restore(cr);
    if (cairo_status(cr) != CAIRO_STATUS_SUCCESS) {
      fail_report(operation, report);
      return;
    }
  }
}

gboolean preview_requested(GtkPrintOperation* operation,
    GtkPrintOperationPreview*, GtkPrintContext* context, GtkWindow*, gpointer data) {
  // GTK's default preview writes a PDF and launches an external viewer. This
  // adapter only submits print jobs; preview is not a successful submission.
  // A handled preview must supply a Cairo context even when cancelled: GTK
  // checks this before its cancellation loop. This surface never leaves RAM.
  cairo_surface_t* surface = cairo_image_surface_create(CAIRO_FORMAT_A8, 1, 1);
  cairo_t* cr = cairo_create(surface);
  gtk_print_context_set_cairo_context(context, cr, 72, 72);
  cairo_destroy(cr);
  cairo_surface_destroy(surface);
  static_cast<Report*>(data)->preview = true;
  gtk_print_operation_cancel(operation);
  return TRUE;
}

void owner_destroyed(GtkWidget* owner, gpointer data) {
  keel_print_report_cancel(GTK_PRINT_OPERATION(data), GTK_WINDOW(owner));
}
}  // namespace

void keel_print_report_cancel(GtkPrintOperation* operation, GtkWindow* owner) {
  // Dialog responses can synchronously destroy the state owning these objects.
  g_autoptr(GtkPrintOperation) retained_operation =
      GTK_PRINT_OPERATION(g_object_ref(operation));
  g_autoptr(GtkWindow) retained_owner = GTK_WINDOW(g_object_ref(owner));
  gtk_print_operation_cancel(retained_operation);
  // cancel() alone does not dismiss GTK's nested print dialog loop. Deliver
  // cancellation to transient dialogs; PrintOperation then destroys them as
  // its synchronous run unwinds. Hold all snapshot objects across signals.
  GList* windows = gtk_window_list_toplevels();
  for (GList* item = windows; item; item = item->next) g_object_ref(item->data);
  for (GList* item = windows; item; item = item->next) {
    auto* window = GTK_WINDOW(item->data);
    GtkWindow* parent = gtk_window_get_transient_for(window);
    while (parent && parent != retained_owner)
      parent = gtk_window_get_transient_for(parent);
    if (parent && GTK_IS_DIALOG(window))
      gtk_dialog_response(GTK_DIALOG(window), GTK_RESPONSE_CANCEL);
  }
  g_list_free_full(windows, g_object_unref);
}

FlMethodCodec* keel_desktop_files_codec_new() {
  return FL_METHOD_CODEC(g_object_new(keel_print_codec_get_type(), nullptr));
}

GtkPrintOperationResult keel_print_report_run(GtkPrintOperation* operation,
    GtkWindow* owner, const gchar* title, const gchar* content) {
  if (!valid_report_text(title, false) || !valid_report_text(content, true))
    return GTK_PRINT_OPERATION_RESULT_ERROR;
  Report report;
  // content is the complete previewed body; do not prepend title.
  // Preserve logical breaks without counting CRLF twice. Unicode paragraph
  // separators also delimit independent layouts to bound Pango coordinates.
  for (const char* cursor = content; *cursor; cursor = g_utf8_next_char(cursor)) {
    const gunichar ch = g_utf8_get_char(cursor);
    if (ch == '\r') {
      report.text.push_back('\n');
      if (cursor[1] == '\n') ++cursor;
    } else if (ch == 0x2028 || ch == 0x2029) {
      report.text.push_back('\n');
    } else {
      report.text.append(cursor, g_utf8_next_char(cursor) - cursor);
    }
  }
  gtk_print_operation_set_allow_async(operation, FALSE);
  gtk_print_operation_set_unit(operation, GTK_UNIT_POINTS);
  gtk_print_operation_set_use_full_page(operation, FALSE);
  gtk_print_operation_set_embed_page_setup(operation, TRUE);
  // Do not put report text or its title into spooler metadata.
  gtk_print_operation_set_job_name(operation, "Keel");
  gtk_print_operation_set_show_progress(operation, FALSE);
  g_signal_connect(operation, "begin-print", G_CALLBACK(begin_print), &report);
  g_signal_connect(operation, "draw-page", G_CALLBACK(draw_page), &report);
  g_signal_connect(operation, "preview", G_CALLBACK(preview_requested), &report);
  const gulong destroy = g_signal_connect(owner, "destroy",
      G_CALLBACK(owner_destroyed), operation);
  g_autoptr(GError) error = nullptr;
  const GtkPrintOperationResult result = gtk_print_operation_run(operation,
      GTK_PRINT_OPERATION_ACTION_PRINT_DIALOG, owner, &error);
  g_signal_handler_disconnect(owner, destroy);
  g_signal_handlers_disconnect_by_data(operation, &report);
  if (report.failed || error) return GTK_PRINT_OPERATION_RESULT_ERROR;
  if (report.preview) return GTK_PRINT_OPERATION_RESULT_CANCEL;
  return result;
}
