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

type Listing struct {
	ID      uint64  `db:"id"`
	Title   string  `db:"title"`
	Buyer   *string `db:"buyer"`
	Version int     `db:"version"`
}

type CheckRow struct {
	ID        uint64  `db:"id"`
	Buyer     *string `db:"buyer"`
	Recipient *string `db:"recipient"`
}

var (
	carIDs     = []uint64{1234}
	buyerNames = []string{"A", "B", "C"}
	rounds     = 10
	errCarSold = errors.New("car already sold")
)

// 不带事务：读完就走，中间有个窗口
func buyWithoutTx(ctx context.Context, db *sqlx.DB, carID uint64, buyer string) error {
	var l Listing
	err := db.GetContext(ctx, &l,
		"SELECT id, title, buyer, version FROM listings WHERE id = ?", carID)
	if errors.Is(err, sql.ErrNoRows) {
		return fmt.Errorf("car %d not found", carID)
	}
	if err != nil {
		return err
	}

	if l.Buyer != nil {
		return errCarSold
	}

	// 故意停一下，让两个 goroutine 有机会都读到空 buyer
	time.Sleep(time.Duration(rand.IntN(100)) * time.Millisecond)

	if _, err := db.ExecContext(ctx,
		"UPDATE listings SET buyer = ? WHERE id = ?", buyer, carID); err != nil {
		return err
	}

	// 关键窗口：让另一个 goroutine 插进来改 listings
	time.Sleep(time.Duration(rand.IntN(100)) * time.Millisecond)

	if _, err := db.ExecContext(ctx,
		"UPDATE invoices SET recipient = ? WHERE listing_id = ?", buyer, carID); err != nil {
		return err
	}
	return nil
}

// 带事务 + 行锁
func buyWithTx(ctx context.Context, db *sqlx.DB, carID uint64, buyer string) error {
	tx, err := db.BeginTxx(ctx, &sql.TxOptions{
		Isolation: sql.LevelReadCommitted,
	})
	if err != nil {
		return err
	}
	defer tx.Rollback() // Commit 之后返回 ErrTxDone，无害

	var l Listing
	err = tx.GetContext(ctx, &l,
		"SELECT id, title, buyer, version FROM listings WHERE id = ? FOR UPDATE", carID)
	if errors.Is(err, sql.ErrNoRows) {
		return fmt.Errorf("car %d not found", carID)
	}
	if err != nil {
		return err
	}

	if l.Buyer != nil {
		return errCarSold
	}

	if _, err := tx.ExecContext(ctx,
		"UPDATE listings SET buyer = ? WHERE id = ?", buyer, carID); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx,
		"UPDATE invoices SET recipient = ? WHERE listing_id = ?", buyer, carID); err != nil {
		return err
	}

	return tx.Commit()
}

// 条件更新：靠 WHERE buyer IS NULL 抢，影响 0 行说明被抢先了。
// 不用事务，也不用锁，只有一个 UPDATE 会成功。
func buyWithConditionalUpdate(ctx context.Context, db *sqlx.DB, carID uint64, buyer string) error {
	var l Listing
	err := db.GetContext(ctx, &l,
		"SELECT id, buyer FROM listings WHERE id = ?", carID)
	if errors.Is(err, sql.ErrNoRows) {
		return fmt.Errorf("car %d not found", carID)
	}
	if err != nil {
		return err
	}
	if l.Buyer != nil {
		return errCarSold
	}

	// 窗口照开，条件更新自己会挡住
	time.Sleep(randomDelay())

	res, err := db.ExecContext(ctx,
		"UPDATE listings SET buyer = ? WHERE id = ? AND buyer IS NULL",
		buyer, carID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return errCarSold
	}

	time.Sleep(randomDelay())

	if _, err := db.ExecContext(ctx,
		"UPDATE invoices SET recipient = ? WHERE listing_id = ?", buyer, carID); err != nil {
		return err
	}
	return nil
}

// 重置数据：把买家清空，车还在，发票行还在
func reset(db *sqlx.DB) error {
	if _, err := db.Exec("UPDATE listings SET buyer = NULL, version = 0"); err != nil {
		return err
	}
	if _, err := db.Exec("UPDATE invoices SET recipient = NULL, version = 0"); err != nil {
		return err
	}
	return nil
}

// 校验：每辆车的 buyer 和 recipient 必须一致
func check(db *sqlx.DB) (bool, []CheckRow) {
	var rows []CheckRow
	err := db.Select(&rows, `
		SELECT l.id, l.buyer, i.recipient
		FROM listings l
		JOIN invoices i ON i.listing_id = l.id
		ORDER BY l.id`)
	if err != nil {
		log.Fatal(err)
	}

	ok := true
	for _, r := range rows {
		switch {
		case r.Buyer == nil && r.Recipient == nil:
			// 都没买，正常
		case r.Buyer != nil && r.Recipient != nil && *r.Buyer == *r.Recipient:
			// 一致，正常
		default:
			ok = false
		}
	}
	return ok, rows
}

func shuffle(ids []uint64) []uint64 {
	out := append([]uint64(nil), ids...)
	rand.Shuffle(len(out), func(i, j int) {
		out[i], out[j] = out[j], out[i]
	})
	return out
}

type buyFunc func(ctx context.Context, db *sqlx.DB, carID uint64, buyer string) error

func runRound(db *sqlx.DB, mode string, buy buyFunc, round int) bool {
	if err := reset(db); err != nil {
		log.Fatal(err)
	}

	ctx := context.Background()
	var wg sync.WaitGroup

	for _, name := range buyerNames {
		wg.Add(1)
		go func(buyer string) {
			defer wg.Done()
			for _, carID := range shuffle(carIDs) {
				err := buy(ctx, db, carID, buyer)
				if errors.Is(err, errCarSold) {
					continue
				}
				if err != nil {
					log.Printf("%s 买 %d 出错: %v", buyer, carID, err)
				}
			}
		}(name)
	}
	wg.Wait()

	ok, rows := check(db)

	fmt.Printf("\n=== %s · 第 %d 次 ===\n", mode, round)
	for _, r := range rows {
		mark := "✓"
		if !(r.Buyer == nil && r.Recipient == nil) &&
			!(r.Buyer != nil && r.Recipient != nil && *r.Buyer == *r.Recipient) {
			mark = "✗"
		}
		fmt.Printf("  %d  buyer=%-8s recipient=%-8s %s\n",
			r.ID, str(r.Buyer), str(r.Recipient), mark)
	}

	if ok {
		fmt.Println("  结论：一致")
	} else {
		fmt.Println("  结论：不一致")
	}
	return ok
}

// 随机的停顿，让多个 goroutine 的时序错开
func randomDelay() time.Duration {
	return time.Duration(rand.IntN(20)+1) * time.Millisecond
}

func str(p *string) string {
	if p == nil {
		return "NULL"
	}
	return *p
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
		name string
		buy  buyFunc
	}{
		{"不用事务", buyWithoutTx},
		{"用事务 + FOR UPDATE", buyWithTx},
		{"条件更新", buyWithConditionalUpdate},
	}

	for _, m := range modes {
		ok := 0
		for i := 1; i <= rounds; i++ {
			if runRound(db, m.name, m.buy, i) {
				ok++
			}
		}
		fmt.Printf("\n%s  %d/%d 次一致\n", m.name, ok, rounds)
	}

	fmt.Println("\n=== 手工构造的交错 ===")
	dirtyWriteByHand(db)
}

// dirtyWriteByHand 手工构造书里的交错，不靠并发。
// 自动提交模式下，每条语句立刻可见，顺序执行也能复现。
func dirtyWriteByHand(db *sqlx.DB) {
	ctx := context.Background()
	if err := reset(db); err != nil {
		log.Fatal(err)
	}

	read := func(who string) {
		var l Listing
		if err := db.GetContext(ctx, &l,
			"SELECT id, buyer FROM listings WHERE id = 1234"); err != nil {
			log.Fatal(err)
		}
		fmt.Printf("  %s 读到 buyer=%v\n", who, str(l.Buyer))
	}
	write := func(sqlStr, what string) {
		if _, err := db.ExecContext(ctx, sqlStr); err != nil {
			log.Fatal(err)
		}
		fmt.Printf("  %s\n", what)
	}

	read("A")
	read("B")

	write("UPDATE listings SET buyer = 'A' WHERE id = 1234", "A 写 listings")
	write("UPDATE listings SET buyer = 'B' WHERE id = 1234", "B 写 listings")
	write("UPDATE invoices SET recipient = 'B' WHERE listing_id = 1234", "B 写 invoices")
	write("UPDATE invoices SET recipient = 'A' WHERE listing_id = 1234", "A 写 invoices")

	ok, rows := check(db)
	for _, r := range rows {
		fmt.Printf("  1234  buyer=%s  recipient=%s\n", str(r.Buyer), str(r.Recipient))
	}
	if ok {
		fmt.Println("  结论：一致")
	} else {
		fmt.Println("  结论：不一致")
	}
}
