#ifndef RUNNER_PRINT_REPORT_H_
#define RUNNER_PRINT_REPORT_H_

#include <windows.h>
#include <functional>
#include <string>

enum class PrintReportResult { printed, cancelled, error };

// Inputs are strictly validated UTF-8, each bounded to 1 MiB.
// The callback must remain valid across all native nested message loops.
PrintReportResult PrintReport(HWND owner, const std::string& title,
                              const std::string& content,
                              const std::function<bool()>& alive) noexcept;

#endif  // RUNNER_PRINT_REPORT_H_
