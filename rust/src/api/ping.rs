use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use flutter_rust_bridge::frb;

/// 跨语言请求 DTO：字段与 Dart 侧一一对应，由 codegen 生成。
#[derive(Debug, Clone)]
pub struct PingRequest {
    pub sequence: i32,
    pub payload: String,
    pub tags: Vec<String>,
}

/// 跨语言响应 DTO：`server_time_ms` 是 UTC epoch 毫秒，显示时由 UI 转本地时区。
#[derive(Debug, Clone)]
pub struct PingResponse {
    pub sequence: i32,
    pub echo: String,
    pub tag_count: i32,
    pub server_time_ms: i64,
    pub work_ms: i64,
}

#[frb(sync)]
pub fn ping(request: PingRequest) -> PingResponse {
    build_response(request, Instant::now(), 0)
}

/// 异步样例：在 Rust 侧模拟一段耗时工作，UI 线程不阻塞。
pub async fn ping_async(request: PingRequest) -> PingResponse {
    let started = Instant::now();
    let simulated_work = Duration::from_millis(300);
    tokio::time::sleep(simulated_work).await;
    build_response(request, started, simulated_work.as_millis() as i64)
}

fn build_response(request: PingRequest, started: Instant, simulated_ms: i64) -> PingResponse {
    let elapsed_ms = started.elapsed().as_millis() as i64;
    PingResponse {
        sequence: request.sequence,
        echo: request.payload,
        tag_count: request.tags.len() as i32,
        server_time_ms: now_epoch_ms(),
        work_ms: simulated_ms + elapsed_ms,
    }
}

fn now_epoch_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis() as i64)
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request() -> PingRequest {
        PingRequest {
            sequence: 7,
            payload: "keel".to_owned(),
            tags: vec!["a".to_owned(), "b".to_owned(), "c".to_owned()],
        }
    }

    #[test]
    fn ping_echoes_request_fields() {
        let response = ping(request());

        assert_eq!(response.sequence, 7);
        assert_eq!(response.echo, "keel");
        assert_eq!(response.tag_count, 3);
        assert!(response.work_ms >= 0);
    }

    #[test]
    fn build_response_reports_simulated_work_and_current_time() {
        let before = now_epoch_ms();
        let response = build_response(request(), Instant::now(), 250);

        assert_eq!(response.work_ms, 250);
        assert!(response.server_time_ms >= before);
    }
}
