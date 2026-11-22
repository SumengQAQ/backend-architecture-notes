-- MySQL 8.x
CREATE DATABASE IF NOT EXISTS data_consistency
    DEFAULT CHARSET utf8mb4;

USE data_consistency;

DROP TABLE IF EXISTS invoices;
DROP TABLE IF EXISTS listings;

-- 车辆表
CREATE TABLE listings (
    id      BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    title   VARCHAR(128)    NOT NULL,
    buyer   VARCHAR(64)     NULL,
    version INT             NOT NULL DEFAULT 0,
    PRIMARY KEY (id)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

-- 发票表：一辆车一张，建车的时候就建好了
-- 书里的脏写是 UPDATE 这张表，所以唯一索引挡不住
CREATE TABLE invoices (
    id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    listing_id BIGINT UNSIGNED NOT NULL,
    recipient  VARCHAR(64)     NULL,
    version    INT             NOT NULL DEFAULT 0,
    PRIMARY KEY (id),
    UNIQUE KEY uk_listing (listing_id)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;
