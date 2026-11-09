#pragma once

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

// StandardMethodCodec on the wire; validates print strings before FlValue can
// discard embedded NUL bytes. Invalid print arguments decode to null arguments.
FlMethodCodec* keel_desktop_files_codec_new();
// Main-thread cancellation also dismisses nested transient print dialogs.
void keel_print_report_cancel(GtkPrintOperation* operation, GtkWindow* owner);
GtkPrintOperationResult keel_print_report_run(GtkPrintOperation* operation,
    GtkWindow* owner, const gchar* title, const gchar* content);
