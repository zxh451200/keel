#include "print_report.h"

#include <commdlg.h>
#include <usp10.h>
#include <algorithm>
#include <vector>

namespace {
bool Decode(const std::string& input, std::wstring* output) {
  if (input.empty() || input.size() > 1024 * 1024 ||
      input.find(char(0)) != std::string::npos) return false;
  const int length = static_cast<int>(input.size());
  const int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                      input.data(), length, nullptr, 0);
  if (count <= 0) return false;
  output->resize(count);
  return MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, input.data(),
                             length, output->data(), count) == count;
}

bool ValidText(const std::wstring& text, bool body) {
  for (size_t i = 0; i < text.size(); ++i) {
    const wchar_t c = text[i];
    const bool allowed = body && (c == 9 || c == 10 || c == 13);
    if ((c < 32 && !allowed) || (c >= 0x7f && c <= 0x9f) ||
        c == 0x2028 || c == 0x2029) return false;
    if (c == 13 || c == 10) {
      if (c == 13 && i + 1 < text.size() && text[i + 1] == 10) ++i;
    }
  }
  return true;
}

struct Printer {
  PRINTDLGW dialog{};
  bool active = false;
  ~Printer() {
    if (active) AbortDoc(dialog.hDC);
    if (dialog.hDC) DeleteDC(dialog.hDC);
    if (dialog.hDevMode) GlobalFree(dialog.hDevMode);
    if (dialog.hDevNames) GlobalFree(dialog.hDevNames);
  }
};

class Font {
 public:
  explicit Font(HDC dc) : dc_(dc) {
    const int dpi = GetDeviceCaps(dc, LOGPIXELSY);
    if (dpi <= 0) return;
    font_ = CreateFontW(-MulDiv(11, dpi, 72), 0, 0, 0, FW_NORMAL, FALSE,
                        FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                        CLIP_DEFAULT_PRECIS, DEFAULT_QUALITY,
                        DEFAULT_PITCH | FF_DONTCARE, L"Segoe UI");
    if (font_) previous_ = SelectObject(dc_, font_);
  }
  ~Font() {
    if (ready()) SelectObject(dc_, previous_);
    if (font_) DeleteObject(font_);
  }
  bool ready() const {
    return font_ && previous_ && previous_ != HGDI_ERROR;
  }
 private:
  HDC dc_;
  HFONT font_ = nullptr;
  HGDIOBJ previous_ = nullptr;
};

class ShapedText {
 public:
  ~ShapedText() { if (value_) ScriptStringFree(&value_); }
  bool Analyse(HDC dc, const wchar_t* text, int count) {
    if (value_) ScriptStringFree(&value_);
    return SUCCEEDED(ScriptStringAnalyse(
        dc, text, count, count * 2 + 32, -1,
        SSA_GLYPHS | SSA_FALLBACK | SSA_LINK | SSA_BREAK, 0,
        nullptr, nullptr, nullptr, nullptr, nullptr, &value_));
  }
  SCRIPT_STRING_ANALYSIS get() const { return value_; }
 private:
  SCRIPT_STRING_ANALYSIS value_ = nullptr;
};

thread_local const std::function<bool()>* current_alive = nullptr;
BOOL CALLBACK KeepPrinting(HDC, int) noexcept {
  try {
    if (!current_alive || !(*current_alive)()) return FALSE;
    // Nested dispatch may destroy the window/engine. Only shared request state
    // is retained by the callback, and is checked after every dispatch.
    MSG message{};
    for (int i = 0; i < 64 && PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE);
         ++i) {
      if (message.message == WM_QUIT) {
        PostQuitMessage(static_cast<int>(message.wParam));
        return FALSE;
      }
      TranslateMessage(&message);
      DispatchMessageW(&message);
      if (!(*current_alive)()) return FALSE;
    }
    return TRUE;
  } catch (...) { return FALSE; }
}
struct AbortScope {
  const std::function<bool()>* previous;
  explicit AbortScope(const std::function<bool()>& alive)
      : previous(current_alive) { current_alive = &alive; }
  ~AbortScope() { current_alive = previous; }
};

// Bound each shaping operation, including for a 1 MiB unbroken line. Extra
// lookahead identifies safe cluster boundaries. All input is consumed in order.
bool NextLine(HDC dc, const std::wstring& text, size_t begin, size_t end,
              int width, ShapedText* line, size_t* consumed, int* height) {
  size_t window = std::min<size_t>(end - begin, 4098);
  if (begin + window < end && text[begin + window - 1] >= 0xd800 &&
      text[begin + window - 1] <= 0xdbff) --window;
  ShapedText probe;
  if (!probe.Analyse(dc, text.data() + begin, static_cast<int>(window)))
    return false;
  const auto* attributes = ScriptString_pLogAttr(probe.get());
  if (!attributes) return false;
  std::vector<int> widths(window);
  if (FAILED(ScriptStringGetLogicalWidths(probe.get(), widths.data())))
    return false;
  size_t fit = 0, soft = 0;
  long long advance = 0;
  const size_t limit = std::min<size_t>(window, 4096);
  for (size_t i = 0; i <= limit; ++i) {
    const bool boundary = i == window || attributes[i].fCharStop;
    if (i > 0 && boundary && advance <= width) {
      fit = i;
      if (i < window && attributes[i].fSoftBreak) soft = i;
    }
    if (i == limit || advance > width) break;
    advance += widths[i];
  }
  if (fit == 0) return false;  // Abort an unfit cluster; never clip it.
  if (begin + fit < end && soft > 0) fit = soft;
  // Joining/ligatures may change at the new line end: recheck actual width.
  while (fit > 0) {
    if (!line->Analyse(dc, text.data() + begin, static_cast<int>(fit)))
      return false;
    const SIZE* size = ScriptString_pSize(line->get());
    if (!size) return false;
    if (size->cx <= width && size->cy > 0) {
      *consumed = fit;
      *height = size->cy;
      return true;
    }
    do { --fit; } while (fit > 0 && !attributes[fit].fCharStop);
  }
  return false;
}

bool Render(Printer* printer, const std::wstring& content,
            const std::function<bool()>& alive) {
  HDC dc = printer->dialog.hDC;
  const int width = GetDeviceCaps(dc, HORZRES);
  const int height = GetDeviceCaps(dc, VERTRES);
  if (width <= 0 || height <= 0 || SetMapMode(dc, MM_TEXT) == 0 ||
      SetBkMode(dc, TRANSPARENT) == 0 ||
      SetTextColor(dc, RGB(0, 0, 0)) == CLR_INVALID) return false;
  Font font(dc);
  TEXTMETRICW metrics{};
  if (!font.ready() || !GetTextMetricsW(dc, &metrics)) return false;
  const int blank_height = metrics.tmHeight + metrics.tmExternalLeading;
  if (blank_height <= 0 || blank_height > height) return false;
  bool page = false;
  int y = 0;
  const auto reserve = [&](int line_height) {
    if (line_height <= 0 || line_height > height || !KeepPrinting(dc, 0))
      return false;
    if (page && line_height > height - y) {
      if (EndPage(dc) <= 0 || !alive()) return false;
      page = false;
    }
    if (!page) {
      if (StartPage(dc) <= 0 || !alive()) return false;
      page = true;
      y = 0;
    }
    return true;
  };
  size_t begin = 0;
  // Preserve CRLF, LF, CR, blank lines, and a trailing empty line.
  while (begin <= content.size()) {
    size_t end = content.find_first_of(L"\r\n", begin);
    if (end == std::wstring::npos) end = content.size();
    if (begin == end) {
      if (!reserve(blank_height)) return false;
      y += blank_height;
    }
    size_t cursor = begin;
    while (cursor < end) {
      if (!alive()) return false;
      ShapedText line;
      size_t consumed = 0;
      int line_height = 0;
      if (!NextLine(dc, content, cursor, end, width, &line, &consumed,
                    &line_height) || !reserve(line_height)) return false;
      if (FAILED(ScriptStringOut(line.get(), 0, y, 0, nullptr, 0, 0, FALSE)) ||
          !alive()) return false;
      cursor += consumed;
      y += line_height;
    }
    if (end == content.size()) break;
    begin = end + 1;
    if (content[end] == wchar_t(13) && begin < content.size() &&
        content[begin] == wchar_t(10)) ++begin;
  }
  return page && EndPage(dc) > 0 && alive();
}

PrintReportResult Run(HWND owner, const std::string& title,
                      const std::string& content,
                      const std::function<bool()>& alive) {
  std::wstring wide_title, wide_content;
  if (!Decode(title, &wide_title) || !Decode(content, &wide_content) ||
      !ValidText(wide_title, false) || !ValidText(wide_content, true) ||
      !alive() || !IsWindow(owner)) return PrintReportResult::error;
  // Keep the abort callback installed until Printer has aborted/released its DC.
  AbortScope abort_scope(alive);
  Printer printer;
  auto& dialog = printer.dialog;
  dialog.lStructSize = sizeof(dialog);
  dialog.hwndOwner = owner;
  dialog.Flags = PD_RETURNDC | PD_NOPAGENUMS | PD_NOSELECTION |
                 PD_USEDEVMODECOPIESANDCOLLATE | PD_HIDEPRINTTOFILE |
                 PD_DISABLEPRINTTOFILE;
  dialog.nMinPage = 1;
  dialog.nMaxPage = 0xffff;
  dialog.nCopies = 1;
  const BOOL accepted = PrintDlgW(&dialog);
  const DWORD dialog_error = accepted ? 0 : CommDlgExtendedError();
  // PrintDlg/StartDoc (e.g. PDF drivers) may run nested message loops.
  if (!alive() || !IsWindow(owner)) return PrintReportResult::error;
  if (!accepted) return dialog_error == 0 ? PrintReportResult::cancelled
                                        : PrintReportResult::error;
  if (!dialog.hDC) return PrintReportResult::error;
  if (SetAbortProc(dialog.hDC, KeepPrinting) <= 0 || !alive())
    return PrintReportResult::error;
  DOCINFOW document{};
  document.cbSize = sizeof(document);
  document.lpszDocName = wide_title.c_str();
  // Clear stale errors: drivers do not always set last-error on failure.
  SetLastError(ERROR_SUCCESS);
  const int job = StartDocW(dialog.hDC, &document);
  if (job <= 0) {
    const DWORD error = GetLastError();
    if (!alive() || !IsWindow(owner)) return PrintReportResult::error;
    return error == ERROR_CANCELLED || job == SP_USERABORT
               ? PrintReportResult::cancelled
               : PrintReportResult::error;
  }
  printer.active = true;
  if (!alive() || !Render(&printer, wide_content, alive))
    return PrintReportResult::error;
  if (!alive() || EndDoc(dialog.hDC) <= 0) return PrintReportResult::error;
  printer.active = false;
  return PrintReportResult::printed;  // Submission, not physical delivery.
}
}  // namespace

PrintReportResult PrintReport(HWND owner, const std::string& title,
                              const std::string& content,
                              const std::function<bool()>& alive) noexcept {
  try { return Run(owner, title, content, alive); }
  catch (...) {
    // RAII aborts active jobs, including allocation failures during layout.
    return PrintReportResult::error;
  }
}
