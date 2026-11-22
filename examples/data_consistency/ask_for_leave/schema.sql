-- MySQL 8.x
CREATE DATABASE IF NOT EXISTS data_consistency
    DEFAULT CHARSET utf8mb4;

USE data_consistency;

DROP TABLE IF EXISTS shift_counter;
DROP TABLE IF EXISTS doctors;

-- 值班医生
CREATE TABLE doctors (
    id      BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    name    VARCHAR(64)     NOT NULL,
    on_duty TINYINT(1)      NOT NULL DEFAULT 1,
    PRIMARY KEY (id)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

-- 物化冲突用：每个班次一行，记当前在岗人数
CREATE TABLE shift_counter (
    shift   VARCHAR(16) NOT NULL,
    on_call INT         NOT NULL,
    PRIMARY KEY (shift)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;
