-- Do not crash during constant folding if encountering a negative
-- exponent.
-- ==
-- input { true } error:

let main b = if b then 2 ** -1 else 0
