-- 应用级登录保护。只保存 Argon2id 校验值，不保存明文口令或可逆密文；
-- 开关默认关闭，且不进入可导入的配置文件（外部配置不能打开/关闭登录）。
CREATE TABLE app_security (
    id             INTEGER PRIMARY KEY CHECK (id = 1),
    password_hash  TEXT,
    login_required INTEGER NOT NULL DEFAULT 0 CHECK (login_required IN (0, 1)),
    updated_at     INTEGER NOT NULL
);
