USE data_consistency;

INSERT INTO listings (id, title) VALUES
    (1234, '2018 本田思域'),
    (1235, '2020 丰田卡罗拉'),
    (1236, '2016 大众高尔夫');

-- 发票行提前建好，下单时只改 recipient
INSERT INTO invoices (listing_id) VALUES
    (1234), (1235), (1236);
