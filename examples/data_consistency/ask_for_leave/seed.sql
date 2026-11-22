USE data_consistency;

INSERT INTO doctors (id, name) VALUES
    (1, 'Alice'),
    (2, 'Bob');

INSERT INTO shift_counter (shift, on_call) VALUES
    ('today', 2);
