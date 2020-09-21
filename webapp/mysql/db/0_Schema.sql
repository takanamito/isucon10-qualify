DROP DATABASE IF EXISTS isuumo;
CREATE DATABASE isuumo;

DROP TABLE IF EXISTS isuumo.estate;
DROP TABLE IF EXISTS isuumo.chair;

CREATE TABLE isuumo.estate
(
    id          INTEGER             NOT NULL PRIMARY KEY,
    name        VARCHAR(64)         NOT NULL,
    description VARCHAR(4096)       NOT NULL,
    thumbnail   VARCHAR(128)        NOT NULL,
    address     VARCHAR(128)        NOT NULL,
    latitude    DOUBLE PRECISION    NOT NULL,
    longitude   DOUBLE PRECISION    NOT NULL,
    point       POINT AS (POINT(latitude, longitude)) STORED NOT NULL,
    rent        INTEGER             NOT NULL,
    door_height INTEGER             NOT NULL,
    door_width  INTEGER             NOT NULL,
    features    VARCHAR(64)         NOT NULL,
    popularity  INTEGER             NOT NULL,
    rev_popularity  INTEGER AS (-popularity) NOT NULL
);

CREATE TABLE isuumo.chair
(
    id          INTEGER         NOT NULL PRIMARY KEY,
    name        VARCHAR(64)     NOT NULL,
    description VARCHAR(4096)   NOT NULL,
    thumbnail   VARCHAR(128)    NOT NULL,
    price       INTEGER         NOT NULL,
    height      INTEGER         NOT NULL,
    width       INTEGER         NOT NULL,
    depth       INTEGER         NOT NULL,
    color       VARCHAR(64)     NOT NULL,
    features    VARCHAR(64)     NOT NULL,
    kind        VARCHAR(64)     NOT NULL,
    popularity  INTEGER         NOT NULL,
    rev_popularity INTEGER AS (-popularity) NOT NULL,
    stock       INTEGER         NOT NULL
);

ALTER TABLE estate ADD SPATIAL INDEX estate_point_idx(point);

CREATE INDEX door_height_rent_index ON isuumo.estate (door_height, rent);
CREATE INDEX door_width_rent_index ON isuumo.estate (door_width, rent);
CREATE INDEX rent_id_index ON isuumo.estate (rent, id);
CREATE INDEX rev_popularity_id_rent_index ON isuumo.estate (rev_popularity, id, rent);
CREATE INDEX latitute_longitude_index ON isuumo.estate (latitude, longitude);

CREATE INDEX stock_index ON isuumo.chair (stock);
CREATE INDEX price_id_index ON isuumo.chair (price, id);
CREATE INDEX popularity_index ON isuumo.chair (rev_popularity, id);
CREATE INDEX price_stock_index ON isuumo.chair (price, stock);
CREATE INDEX kind_stock_index ON isuumo.chair (kind, stock);
CREATE INDEX height_stock_index ON isuumo.chair (height, stock);
CREATE INDEX width_stock_index ON isuumo.chair (width, stock);
CREATE INDEX color_stock_index ON isuumo.chair (color, stock);
CREATE INDEX depth_stock_index ON isuumo.chair (depth, stock);
