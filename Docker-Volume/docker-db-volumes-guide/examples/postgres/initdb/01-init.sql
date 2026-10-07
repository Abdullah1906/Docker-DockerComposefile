-- Init script: শুধু প্রথমবার চলে (data directory খালি থাকলে)
CREATE TABLE IF NOT EXISTS products (
    id    SERIAL PRIMARY KEY,
    name  TEXT NOT NULL,
    price NUMERIC(10,2)
);

INSERT INTO products (name, price) VALUES
    ('Laptop', 999.99),
    ('Mouse', 19.99);
