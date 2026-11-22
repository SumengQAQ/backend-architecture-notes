package config

import (
	"fmt"
	"net"
	"os"
	"time"

	"github.com/go-sql-driver/mysql"
	"github.com/jmoiron/sqlx"
	"github.com/joho/godotenv"
)

// LoadDSN 从 .env 和环境变量里拼出 DSN。
// 优先级：环境变量 > .env > 代码里的默认值。
func LoadDSN() (string, error) {
	// .env 不存在不报错，方便 CI 里只给环境变量
	if err := godotenv.Load(); err != nil && !os.IsNotExist(err) {
		return "", fmt.Errorf("load .env: %w", err)
	}

	cfg := mysql.NewConfig()
	cfg.User = getEnv("DB_USER", "root")
	cfg.Passwd = os.Getenv("DB_PASS")
	cfg.Net = "tcp"
	cfg.Addr = net.JoinHostPort(
		getEnv("DB_HOST", "127.0.0.1"),
		getEnv("DB_PORT", "3306"),
	)
	cfg.DBName = getEnv("DB_NAME", "data_consistency")
	cfg.ParseTime = true
	cfg.Loc = time.Local
	cfg.Params = map[string]string{
		"charset": "utf8mb4",
	}

	return cfg.FormatDSN(), nil
}

// Open 打开连接池。不会立刻建连，第一次用到才连。
func Open() (*sqlx.DB, error) {
	dsn, err := LoadDSN()
	if err != nil {
		return nil, err
	}

	db, err := sqlx.Open("mysql", dsn)
	if err != nil {
		return nil, err
	}

	db.SetMaxOpenConns(20)
	db.SetMaxIdleConns(20)
	db.SetConnMaxLifetime(3 * time.Minute)

	return db, nil
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
