# Adapter for the Stage 2 C11 backend and its Decimal runtime.

BACKEND_NAME=c11-stage2
. "$KOFUN_ROOT/bootstrap/stage2/build.sh"

backend_compile() {
    source=$1
    output=$2
    work=$3
    emitted="$work/program.c"
    stage2=$(dirname "$work")/kofun-stage2

    if test ! -x "$stage2"; then
        kofun_stage2_build "$KOFUN_ROOT" "$stage2"
    fi

    "$stage2" \
        "$source" "$emitted" "$work/program.ir" "$work/program.tokens" \
        >"$work/emit.stdout" 2>"$work/emit.stderr" || {
        cat "$work/emit.stdout" "$work/emit.stderr"
        rm -f "$emitted" "$work/program.ir" "$work/program.tokens"
        return 1
    }

    compiler=${CC:-cc}
    "$compiler" -std=c11 -O2 -Wall -Wextra -Werror \
        -I"$KOFUN_ROOT/bootstrap/stage2" \
        "$emitted" -o "$output"
}
