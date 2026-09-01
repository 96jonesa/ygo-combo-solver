#!/usr/bin/env bash
# POSIX port of fetch_solver_deps.ps1 — same pinned commits, same five arena
# patches, same layout. See the .ps1 header for the full rationale; in brief:
# the solver must run on an ocgcore CONTEMPORARY with the analysed replay
# (a mismatch diverges silently), so a precise commit plus its matching
# lua/src are extracted into deps/ocgcore/, patched for the memory snapshot,
# and a card-script export is frozen at the reference replay's date.
#
# Like the .ps1, this expects the replay2video layout: an edopro/ clone with
# an initialized ocgcore submodule (and its lua/src submodule) as a sibling
# of this repository's parent. It never writes into that clone.
set -euo pipefail

COMMIT="${COMMIT:-5a985af7c43c8470b06bef697bfb9051b40e114c}"
DEST="${DEST:-deps/ocgcore}"
SCRIPTS_COMMIT="${SCRIPTS_COMMIT:-0e90a3e8}"
SCRIPTS_DATE="${SCRIPTS_DATE:-2026-04-13}"

script_dir="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$(dirname "$script_dir")")"
src="$root/edopro/ocgcore"
dst="$root/$DEST"

if [ ! -e "$src/.git" ]; then
    echo "error: edopro/ocgcore not found at $src (clone edopro with its ocgcore submodule first)" >&2
    exit 1
fi

# Fetching is only useful when the commit is missing locally: a network outage
# must not stop a rebuild from objects that are already there.
if [ "$(git -C "$src" cat-file -t "$COMMIT" 2>/dev/null)" = "commit" ]; then
    echo "ocgcore objects already present locally"
else
    echo "fetching ocgcore objects..."
    git -C "$src" fetch --quiet origin
fi

# The lua/src pin is carried by the target commit's tree, not by HEAD.
lua_commit="$(git -C "$src" ls-tree "$COMMIT" lua/src | awk '{print $3}')"
if [ -z "$lua_commit" ]; then
    echo "error: commit $COMMIT not found, or has no lua/src" >&2
    exit 1
fi
echo "  ocgcore : $COMMIT"
echo "  lua/src : $lua_commit"

rm -rf "$dst"
mkdir -p "$dst/lua/src"

echo "extracting ocgcore..."
git -C "$src" archive "$COMMIT" | tar -x -C "$dst"

echo "extracting lua..."
lua_src="$src/lua/src"
if [ "$(git -C "$lua_src" cat-file -t "$lua_commit" 2>/dev/null)" != "commit" ]; then
    git -C "$lua_src" fetch --quiet origin
fi
git -C "$lua_src" archive "$lua_commit" | tar -x -C "$dst/lua/src"

# --- patches for the memory snapshot (see the .ps1 for full commentary) -----
echo "applying the arena patches..."
python3 - "$dst" "$COMMIT" "$lua_commit" <<'PYEOF'
import json, sys, time, os
dst = sys.argv[1]

def apply(path, anchor, replacement, label):
    with open(path, newline="") as f:
        t = f.read()
    if replacement in t:
        print(f"  {label}: already applied"); return
    if anchor not in t:
        sys.exit(f"patch '{label}': anchor not found in {path}. The ocgcore version changed and the patch must be revised.")
    with open(path, "w", newline="") as f:
        f.write(t.replace(anchor, replacement))
    print(f"  {label}: ok")

HOOK_DECL = """/* ---- combosolver: memory snapshot of the duel ---------------------------- */
/* Constant string hash seed: makes the core reproducible from one run to the
   next. Without it, luai_makeseed mixes a stack address and the clock
   (lstate.c). The seed only serves the anti-collision protection. */
#define luai_makeseed(L) ((void)(L), 0u)

/* Allocator supplied by the host. Left null, Lua uses realloc/free. When it is
   filled in, the WHOLE Lua heap (tables, closures, upvalues, suspended
   coroutines) lives in the arena and becomes snapshottable. */
#include <stddef.h>
#if defined(__cplusplus)
extern "C" {
#endif
/* Thread-local: each worker has its own arena, and the Lua state it creates
   must draw from that one. A global pointer would mix them up. */
typedef void* (*combosolver_alloc_fn)(void* ud, void* ptr, size_t osize, size_t nsize);
extern thread_local combosolver_alloc_fn combosolver_lua_alloc;
extern thread_local void* combosolver_lua_alloc_ud;
/* Lua state of the last duel created on this thread. The core does not expose
   it, and it has to be reachable in order to stop the garbage collector: its
   marking writes into the header of EVERY live object, which dirties nearly
   every page and ruins the point of an incremental restore. With no GC, no
   memory is lost: a restore reclaims everything an abandoned branch
   allocated. */
extern thread_local void* combosolver_lua_state;
#if defined(__cplusplus)
}
#endif
/* -------------------------------------------------------------------------- */

"""
PROC_STATE = """/* --- combosolver: processor state ------------------------------------------
   Serialises what the zones do not say: the stack of units being resolved, the
   current chain, the per-turn activation counters, the phase and the life
   points. Complements the solver's transposition key. */
static uint16_t combosolver_unit_step(const processor_unit& u) {
	return std::visit([](const auto& arg) -> uint16_t {
		using T = std::decay_t<decltype(arg)>;
		if constexpr(Processors::IsProcess<T>)
			return static_cast<uint16_t>(arg.step);
		else
			return 0;
	}, u);
}
static void combosolver_dump_counts(std::vector<uint8_t>& buf,
									const std::unordered_map<uint64_t, uint32_t>& m) {
	/* Sorted: an unordered_map has no stable order, and an unstable key would
	   make the digest non-deterministic. */
	std::vector<std::pair<uint64_t, uint32_t>> sorted(m.begin(), m.end());
	std::sort(sorted.begin(), sorted.end());
	insert_value<uint32_t>(buf, sorted.size());
	for(const auto& kv : sorted) {
		insert_value<uint64_t>(buf, kv.first);
		insert_value<uint32_t>(buf, kv.second);
	}
}
/* No OCGAPI prefix here: in this version of the core the linkage is carried by
   the header declaration, and the definitions do not repeat it. */
void* OCG_DuelQueryProcessorState(OCG_Duel ocg_duel, uint32_t* length) {
	auto* pduel = static_cast<duel*>(ocg_duel);
	auto& field = *pduel->game_field;
	auto& buf = pduel->query_buffer;
	buf.clear();

	insert_value<uint16_t>(buf, field.infos.phase);
	insert_value<int16_t>(buf, field.infos.turn_id);
	insert_value<uint8_t>(buf, field.infos.turn_player);
	for(int p = 0; p < 2; ++p) {
		insert_value<int32_t>(buf, field.player[p].lp);
		insert_value<int32_t>(buf, field.core.summon_count[p]);
		insert_value<uint32_t>(buf, field.player[p].used_location);
		insert_value<uint32_t>(buf, field.player[p].extra_p_count);
	}
	/* Resolution stack: it is what tells apart two instants with an identical
	   board in the middle of the same chain. */
	insert_value<uint32_t>(buf, field.core.units.size());
	for(const auto& u : field.core.units) {
		insert_value<uint8_t>(buf, u.index());
		insert_value<uint16_t>(buf, combosolver_unit_step(u));
	}
	insert_value<uint32_t>(buf, field.core.subunits.size());
	for(const auto& u : field.core.subunits) {
		insert_value<uint8_t>(buf, u.index());
		insert_value<uint16_t>(buf, combosolver_unit_step(u));
	}
	insert_value<uint32_t>(buf, field.core.current_chain.size());
	for(const auto& ch : field.core.current_chain) {
		insert_value<uint16_t>(buf, ch.chain_id);
		insert_value<uint8_t>(buf, ch.triggering_player);
		insert_value<uint32_t>(buf, ch.event_id);
		insert_value<uint32_t>(buf, ch.flag);
	}
	combosolver_dump_counts(buf, field.core.effect_count_code);
	combosolver_dump_counts(buf, field.core.effect_count_code_duel);
	combosolver_dump_counts(buf, field.core.effect_count_code_chain);

	if(length)
		*length = static_cast<uint32_t>(buf.size());
	return buf.data();
}

"""
LAUXLIB_ANCHOR = """  lua_State *L = lua_newstate(l_alloc, NULL);"""
LAUXLIB_REPL = """  lua_State *L = combosolver_lua_alloc
                   ? lua_newstate((lua_Alloc)combosolver_lua_alloc,
                                  combosolver_lua_alloc_ud)
                   : lua_newstate(l_alloc, NULL);
  combosolver_lua_state = L;"""
H_ANCHOR = """OCGAPI void* OCG_DuelQueryField(OCG_Duel ocg_duel, uint32_t* length);"""
H_REPL = """OCGAPI void* OCG_DuelQueryField(OCG_Duel ocg_duel, uint32_t* length);

/* combosolver: processor state, invisible from the zones alone. */
OCGAPI void* OCG_DuelQueryProcessorState(OCG_Duel ocg_duel, uint32_t* length);"""

apply(os.path.join(dst, "lua/luaconf-customize.h"),
      "#if defined(LUA_EPRO_APICHECK)",
      HOOK_DECL + "#if defined(LUA_EPRO_APICHECK)",
      "luaconf-customize.h (seed + allocator hook)")
apply(os.path.join(dst, "lua/src/lauxlib.c"),
      LAUXLIB_ANCHOR, LAUXLIB_REPL,
      "lauxlib.c (luaL_newstate -> arena allocator + state export)")
apply(os.path.join(dst, "ocgapi.cpp"),
      "void* OCG_DuelQueryField(OCG_Duel ocg_duel, uint32_t* length) {",
      PROC_STATE + "void* OCG_DuelQueryField(OCG_Duel ocg_duel, uint32_t* length) {",
      "ocgapi.cpp (OCG_DuelQueryProcessorState)")
apply(os.path.join(dst, "ocgapi.cpp"),
      "#include <cstring> //std::memcpy",
      "#include <algorithm> //std::sort\n#include <cstring> //std::memcpy",
      "ocgapi.cpp (include algorithm)")
apply(os.path.join(dst, "ocgapi.h"), H_ANCHOR, H_REPL, "ocgapi.h (declaration)")

with open(os.path.join(dst, "SOLVER_DEPS.json"), "w") as f:
    json.dump({"ocgcore": sys.argv[2], "lua": sys.argv[3], "patched": True,
               "fetched": time.strftime("%Y-%m-%dT%H:%M:%S%z")}, f, indent=2)
    f.write("\n")
PYEOF

# --- Card scripts contemporary with the replay ------------------------------
scripts_dst="$root/deps/scripts_$SCRIPTS_DATE"
if [ -d "$scripts_dst/script" ]; then
    echo "scripts already extracted -> deps/scripts_$SCRIPTS_DATE"
else
    scripts_src="$root/deps/CardScripts.git"
    if [ ! -d "$scripts_src" ]; then
        echo "cloning the script repository (once)..."
        git clone --quiet --bare https://github.com/ProjectIgnis/CardScripts.git "$scripts_src"
    fi
    if [ "$(git -C "$scripts_src" cat-file -t "$SCRIPTS_COMMIT" 2>/dev/null)" != "commit" ]; then
        git -C "$scripts_src" fetch --quiet origin
    fi
    mkdir -p "$scripts_dst/script"
    git -C "$scripts_src" archive "$SCRIPTS_COMMIT" | tar -x -C "$scripts_dst/script"
    echo "scripts -> deps/scripts_$SCRIPTS_DATE  ($SCRIPTS_COMMIT)"
fi

echo "ok -> $DEST"
echo "  $(find "$dst" -maxdepth 1 -name '*.cpp' | wc -l | tr -d ' ') .cpp files, lua $(find "$dst/lua/src" -maxdepth 1 -name '*.c' | wc -l | tr -d ' ') .c files"
