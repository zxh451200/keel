//! 业务操作和事务边界，不直接写 SQL。

pub mod access;
pub mod audit;
pub mod audit_export;
pub mod audit_export_history;
pub mod auth;
pub mod backup;
pub mod customer;
pub mod grid_preferences;
pub mod user_import;
// Internal preparation is tested without exposing a public API/FRB entry.
#[cfg_attr(not(test), allow(dead_code))]
pub(crate) mod diagnostic_input;
pub mod diagnostic_pack;
// Isolated POC is exercised by an integration test, not product startup.
#[allow(dead_code)]
pub(crate) mod grid_fixture;
pub mod settings;
pub mod startup;

pub mod diagnostic_history;
