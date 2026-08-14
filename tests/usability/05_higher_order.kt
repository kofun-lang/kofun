// Comparison for corpus item 5: a higher-order API with two ordinary
// arguments and one callback.
//
// Language: Kotlin. Chosen because #624 cites Kotlin's higher-order and
// trailing lambdas (https://kotlinlang.org/docs/lambdas.html) as the
// evidence to evaluate, and because this row is exactly the question #625
// and its slices #880/#881/#882 own. #909 does not decide that question;
// this file is the evidence a decision would be made against.
//
// NOT COMPILED BY THE GATE. No `kotlinc` is present in this repository's CI
// image, so tests/usability/check.sh reports this file as skipped by name
// rather than pretending to have run it.
//
// What to compare: the Kofun file does not compile. Not "compiles less
// prettily" — a function-typed parameter cannot be declared at all, on any
// frontend, and the diagnostic does not say so. It says
//
//     error[E2S12]: invalid Int expression at byte 1211
//
// which points at the call and says the argument is not a valid expression.
// Until #1411 it said `error[E2S17]: Core function `accumulate` expects 3
// arguments, got -1` -- an arity computed from a parameter list it had failed
// to parse, reported as a count. That was the worst diagnostic in this corpus.
// The message still does not say that a function-typed argument is a known
// unimplemented form, which is why the row scores 1 and not more.
//
// Two Kotlin spellings are shown below because #624 warns against "multiple
// overlapping spellings" and #625's decision is precisely whether to adopt
// the second one. Kotlin has both; a reader has to know that
// `accumulate(1, 2) { ... }` and `accumulate(1, 2, { ... })` are the same
// call. That cost is real, and it is the argument against trailing lambdas,
// not for them.

fun accumulate(start: Int, step: Int, combine: (Int, Int) -> Int): Int {
    val first = combine(start, step)
    return combine(first, step)
}

fun main() {
    // Ordinary argument position.
    println(accumulate(1, 2, { left, right -> left + right }))

    // Trailing-lambda position. Same call, different spelling.
    println(accumulate(1, 2) { left, right -> left + right })
}
