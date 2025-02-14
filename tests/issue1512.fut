module type Size = {
  val n: i64
}

module SizeOps (size: Size) = {
  let test (arr: []i64) = arr :> [size.n]i64
}

module mySize = {
  let n = 4i64
} : Size

module mySizeOps = SizeOps mySize

entry main (arr: []i64) =
    mySizeOps.test arr
