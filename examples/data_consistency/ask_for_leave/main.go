package main

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log"
	"math/rand/v2"
	"sync"
	"time"

	"data_consistency/config"

	"github.com/jmoiron/sqlx"
)

var (
	doctorIDs = []uint64{1, 2}
	rounds    = 5

	errWouldLeaveNone = errors.New("至少要有一个人在岗")
)

// 不加锁：查完人数就直接改，中间留个窗口
func requestLeaveWithoutLock(ctx context.Context, db *sqlx.DB, doctorID uint64) error {
	var n int
	if err := db.GetContext(ctx, &n,
		"SELECT COUNT(*) FROM doctors WHERE on_duty = 1"); err != nil {
		return err
	}
	if n <= 1 {
		return errWouldLeaveNone
	}

	// 故意停一下，让两个人都读到 2
	time.Sleep(randomDelay())

	_, err := db.ExecContext(ctx,
		"UPDATE doctors SET on_duty = 0 WHERE id = ?", doctorID)
	return err
}

// 锁住在岗的那些行，别人进不来
func requestLeaveWithLock(ctx context.Context, db *sqlx.DB, doctorID uint64) error {
	tx, err := db.BeginTxx(ctx, &sql.TxOptions{
		Isolation: sql.LevelRepeatableRead,
	})
	if err != nil {
		return err
	}
	defer tx.Rollback()

	var ids []uint64
	if err := tx.SelectContext(ctx, &ids,
		"SELECT id FROM doctors WHERE on_duty = 1 FOR UPDATE"); err != nil {
		return err
	}
	if len(ids) <= 1 {
		return errWouldLeaveNone
	}

	if _, err := tx.ExecContext(ctx,
		"UPDATE doctors SET on_duty = 0 WHERE id = ?", doctorID); err != nil {
		return err
	}

	return tx.Commit()
}

// 物化冲突：先抢班次计数，抢到才请假
func requestLeaveWithCounter(ctx context.Context, db *sqlx.DB, doctorID uint64) error {
	res, err := db.ExecContext(ctx,
		"UPDATE shift_counter SET on_call = on_call - 1 WHERE shift = 'today' AND on_call > 1")
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return errWouldLeaveNone
	}

	time.Sleep(randomDelay())

	_, err = db.ExecContext(ctx,
		"UPDATE doctors SET on_duty = 0 WHERE id = ?", doctorID)
	return err
}

func reset(db *sqlx.DB) error {
	if _, err := db.Exec("UPDATE doctors SET on_duty = 1"); err != nil {
		return err
	}
	if _, err := db.Exec("UPDATE shift_counter SET on_call = (SELECT COUNT(*) FROM doctors)"); err != nil {
		return err
	}
	return nil
}

func check(db *sqlx.DB) (bool, int) {
	var n int
	if err := db.Get(&n, "SELECT COUNT(*) FROM doctors WHERE on_duty = 1"); err != nil {
		log.Fatal(err)
	}
	return n >= 1, n
}

func randomDelay() time.Duration {
	return time.Duration(rand.IntN(20)+1) * time.Millisecond
}

type leaveFunc func(ctx context.Context, db *sqlx.DB, doctorID uint64) error

func runRound(db *sqlx.DB, mode string, leave leaveFunc, round int) bool {
	if err := reset(db); err != nil {
		log.Fatal(err)
	}

	ctx := context.Background()
	var wg sync.WaitGroup

	for _, id := range doctorIDs {
		wg.Add(1)
		go func(d uint64) {
			defer wg.Done()
			err := leave(ctx, db, d)
			if errors.Is(err, errWouldLeaveNone) {
				return
			}
			if err != nil {
				log.Printf("医生 %d 请假出错: %v", d, err)
			}
		}(id)
	}
	wg.Wait()

	ok, n := check(db)
	fmt.Printf("\n=== %s · 第 %d 次 ===\n", mode, round)
	fmt.Printf("  在岗 %d 人\n", n)
	if ok {
		fmt.Println("  结论：没问题")
	} else {
		fmt.Println("  结论：没人在岗了")
	}
	return ok
}

func main() {
	db, err := config.Open()
	if err != nil {
		log.Fatal(err)
	}
	defer db.Close()

	if err := db.Ping(); err != nil {
		log.Fatal(err)
	}

	modes := []struct {
		name  string
		leave leaveFunc
	}{
		{"不加锁", requestLeaveWithoutLock},
		{"FOR UPDATE 锁住在岗行", requestLeaveWithLock},
		{"物化冲突（班次计数）", requestLeaveWithCounter},
	}

	for _, m := range modes {
		ok := 0
		for i := 1; i <= rounds; i++ {
			if runRound(db, m.name, m.leave, i) {
				ok++
			}
		}
		fmt.Printf("\n%s  %d/%d 次正常\n", m.name, ok, rounds)
	}
}
