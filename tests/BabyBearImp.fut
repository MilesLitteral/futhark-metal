-- ==
-- input {
-- }
-- output {
--   [[2,4,5],[1,5,3],[3,7,1]]
-- }

--------------------------------------------------
-- SAC VERSIOn
--------------------------------------------------
--inline i32[.,.] floydSbs1(i32[.,.] d ) [
--    dT = transpose(d);
--    res = with
--        (. <= [i,j] <= .) :
--            min( d[i,j], minval( d[i] + dT[j]));
--        : modarray(d);
--    return( res);
--]



--------------------------------------------------
-- C VERSIOn
--------------------------------------------------
--inline i32* floydSbs1( i32 n, i32* d ) [
--    do k = 1, n
--      do i = 1, n
--        do j = 1, n
--          d[i,j] = min(d[i,j], d[i,k] + d[k,j])
--        enddo
--      enddo
--    enddo

--------------------------------------------------
-- C VERSIOn
--------------------------------------------------
--inline i32* floydSbs1( i32 n, i32* d ) [
--    do i = 1, n
--      do j = 1, n
--        minrow = 0;
--        do k = 1, n
--          minrow = min(minrow, d[i,k] + d[k,j])
--        enddo
--        d[i,j] = min(d[i,j], minrow)
--      enddo
--    enddo

fun min(a: i32) (b: i32): i32 = if(a<b) then a else b

fun floydSbsImp(n: i32, d: *[][]i32): [][]i32 =
    let dT = transpose(d) in
    loop (d = copy d) = for i < n do
        loop (d) = for j < n do
            let sumrow = map (+) d[i] dT[j]
            let minrow = reduce min 1200 sumrow
            let minrow = min d[i,j] minrow
            let d[i,j] = minrow
            in d
        in d
    in d

fun main(): [][]i32 =
    let arr = [[2,4,5], [1,1000,3], [3,7,1]] in
    floydSbsImp(3, copy(arr))
