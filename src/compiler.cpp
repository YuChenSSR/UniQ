#include "compiler.h"

#include <cstring>
#include <algorithm>
#include <assert.h>
#include <set>
#include "dbg.h"
#include "logger.h"
#include "evaluator.h"

Compiler::Compiler(int numQubits, std::vector<Gate> inputGates, int globalBit_):
    numQubits(numQubits), globalBit(globalBit_), localSize(numQubits - globalBit_), gates(inputGates) {}


void Compiler::fillLocals(LocalGroup& lg) {
    int numLocalQubits = numQubits - globalBit;
    for (auto& gg: lg.fullGroups) {
        idx_t related = gg.relatedQubits;
        int numRelated = bitCount(related);
        assert(numRelated <= numLocalQubits);
        if (numRelated < numLocalQubits) {
            for (int i = 0;; i++)
                if (!(related >> i & 1)) {
                    related |= ((idx_t) 1) << i;
                    numRelated ++;
                    if (numRelated == numLocalQubits)
                        break;
                }
        }
        gg.relatedQubits = related;
    }
}

std::vector<std::pair<std::vector<Gate>, idx_t>> Compiler::moveToNext(LocalGroup& lg) {
    std::vector<std::pair<std::vector<Gate>, idx_t>> result;
#ifndef ENABLE_OVERLAP
    for (size_t i = 0; i < lg.fullGroups.size(); i++) {
        result.push_back(make_pair(std::vector<Gate>(), 0));
    }
    return result;
#endif
    result.push_back(make_pair(std::vector<Gate>(), 0));
    for (size_t i = 1; i < lg.fullGroups.size(); i++) {
        std::vector<Gate> gates = lg.fullGroups[i-1].gates;
        std::reverse(gates.begin(), gates.end());
        assert(lg.fullGroups[i-1].relatedQubits != 0);
#if GPU_BACKEND == 3
        SimpleCompiler backCompiler(numQubits, numQubits - 2 * globalBit, numQubits - 2 * globalBit, gates,
                                        false, lg.fullGroups[i-1].relatedQubits, lg.fullGroups[i].relatedQubits);
#else
        SimpleCompiler backCompiler(numQubits, numQubits - 2 * globalBit, numQubits - 2 * globalBit, gates,
                                        true, lg.fullGroups[i-1].relatedQubits, lg.fullGroups[i].relatedQubits);
#endif
        LocalGroup toRemove = backCompiler.run();
        if (toRemove.fullGroups.size() == 0) {
            result.push_back(make_pair(std::vector<Gate>(), 0));
            continue;
        }
        assert(toRemove.fullGroups.size() == 1);
        std::vector<Gate> toRemoveGates = toRemove.fullGroups[0].gates;
        std::reverse(toRemoveGates.begin(), toRemoveGates.end());
        
        removeGates(lg.fullGroups[i-1].gates, toRemoveGates); // TODO: can we optimize this remove?
        result.push_back(make_pair(toRemoveGates, toRemove.fullGroups[0].relatedQubits));
        lg.fullGroups[i].relatedQubits |= toRemove.relatedQubits;
    }
    return result;
}

Schedule Compiler::run() {
#if MODE == 2
    bool enableGlobal = false;
#else
    bool enableGlobal = true;
#endif
    int inplaceSize = std::min(INPLACE, localSize - 2);
    SimpleCompiler localCompiler(numQubits, localSize, (idx_t) -1, gates, enableGlobal, 0, (1 << inplaceSize) - 1);
    LocalGroup localGroup = localCompiler.run();
    auto moveBack = moveToNext(localGroup);
    fillLocals(localGroup);
    Schedule schedule;
    State state(numQubits);
    int numLocalQubits = numQubits - globalBit;
    for (size_t id = 0; id < localGroup.fullGroups.size(); id++) {
        auto& gg = localGroup.fullGroups[id];

        std::vector<int> newGlobals;
        for (int i = 0; i < numQubits; i++) {
            if (! (gg.relatedQubits >> i & 1)) {
                newGlobals.push_back(i);
            }
        }
        assert(int(newGlobals.size()) == globalBit);
        
        auto globalPos = [this, numLocalQubits](const std::vector<int>& layout, int x) {
            auto pos = std::find(layout.data() + numLocalQubits, layout.data() + numQubits, x);
            return std::make_tuple(pos != layout.data() + numQubits, pos - layout.data() - numLocalQubits);
        };

        idx_t overlapGlobals = 0;
        int overlapCnt = 0;
        // put overlapped global qubit into the previous position
        bool modified = true;
        while (modified) {
            modified = false;
            overlapGlobals = 0;
            overlapCnt = 0;
            for (size_t i = 0; i < newGlobals.size(); i++) {
                bool isGlobal;
                int p;
                std::tie(isGlobal, p) = globalPos(state.layout, newGlobals[i]);
                if (isGlobal) {
                    std::swap(newGlobals[p], newGlobals[i]);
                    overlapGlobals |= idx_t(1) << p;
                    overlapCnt ++;
                    if (p != int(i)) {
                        modified = true;
                    }
                }
            }
        }
#ifdef SHOW_SCHEDULE
        printf("globals: "); for (auto x: newGlobals) printf("%d ", x); printf("\n");
#endif

        LocalGroup lg;
        lg.relatedQubits = gg.relatedQubits;
        if (id == 0) {
            state = lg.initFirstGroupState(state, numQubits, newGlobals);
        } else {
            if (INPLACE) {
                state = lg.initStateInplace(state, numQubits, newGlobals, overlapGlobals, globalBit);
            } else {
                state = lg.initState(state, numQubits, newGlobals, overlapGlobals, moveBack[id].second, globalBit);
            }

        }

        idx_t overlapLocals = gg.relatedQubits;
        idx_t overlapBlasForbid = 0;
        if (id > 0) {
            overlapLocals &= localGroup.fullGroups[id - 1].relatedQubits;
            overlapBlasForbid = (~localGroup.fullGroups[id - 1].relatedQubits) & gg.relatedQubits;
            // printf("overlapBlasForbid %llx\n", overlapBlasForbid);
        }
        AdvanceCompiler overlapCompiler(numQubits, overlapLocals, overlapBlasForbid, moveBack[id].first, enableGlobal, globalBit);
        AdvanceCompiler fullCompiler(numQubits, gg.relatedQubits, 0, gg.gates, enableGlobal, globalBit);
        switch (GPU_BACKEND) {
            case 1: // no break;
            case 2: {
                lg.overlapGroups = overlapCompiler.run(state, true, false, LOCAL_QUBIT_SIZE, BLAS_MAT_LIMIT, numLocalQubits - globalBit).fullGroups;
                lg.fullGroups = fullCompiler.run(state, true, false, LOCAL_QUBIT_SIZE, BLAS_MAT_LIMIT, numLocalQubits).fullGroups;
                break;
            }
            case 3: // no break
            case 5: {
                for (auto& g: gg.gates) {
                    if (g.controlQubit == -2 && bitCount(g.encodeQubit) + 1 > BLAS_MAT_LIMIT) {
                        UNIMPLEMENTED();
                    }
                }
                lg.overlapGroups = overlapCompiler.run(state, false, true, LOCAL_QUBIT_SIZE, BLAS_MAT_LIMIT, numLocalQubits - globalBit).fullGroups;
                lg.fullGroups = fullCompiler.run(state, false, true, LOCAL_QUBIT_SIZE, BLAS_MAT_LIMIT, numLocalQubits).fullGroups;
                break;
            }
            case 4: {
                lg.overlapGroups = overlapCompiler.run(state, true, true, LOCAL_QUBIT_SIZE, BLAS_MAT_LIMIT, numLocalQubits - globalBit).fullGroups;
                lg.fullGroups = fullCompiler.run(state, true, true, LOCAL_QUBIT_SIZE, BLAS_MAT_LIMIT, numLocalQubits).fullGroups;
                break;
            }
            default: {
                UNREACHABLE()
                break;
            }
        }
        schedule.localGroups.push_back(std::move(lg));
    }
    schedule.finalState = state;
    return schedule;
}

template<int MAX_GATES>
OneLayerCompiler<MAX_GATES>::OneLayerCompiler(int numQubits, const std::vector<Gate> &inputGates):
    numQubits(numQubits), remainGates(inputGates) {}

SimpleCompiler::SimpleCompiler(int numQubits, int localSize, idx_t localQubits, const std::vector<Gate>& inputGates, bool enableGlobal, idx_t whiteList, idx_t required):
    OneLayerCompiler<2048>(numQubits, inputGates), localSize(localSize), localQubits(localQubits), enableGlobal(enableGlobal), whiteList(whiteList), required(required) {}

AdvanceCompiler::AdvanceCompiler(int numQubits, idx_t localQubits, idx_t blasForbid, std::vector<Gate> inputGates, bool enableGlobal, int globalBit_):
    OneLayerCompiler<512>(numQubits, inputGates), localQubits(localQubits), blasForbid(blasForbid), enableGlobal(enableGlobal), globalBit(globalBit_) {}

LocalGroup SimpleCompiler::run() {
    LocalGroup lg;
    if (localSize == numQubits) {
        GateGroup gg;
        for (auto& g: remainGates)
            gg.addGate(g, localQubits, enableGlobal);
        lg.relatedQubits = gg.relatedQubits;
        lg.fullGroups.push_back(gg.copyGates());
        return lg;
    }
    lg.relatedQubits = 0;
    remain.clear();
    for (size_t i = 0; i < remainGates.size(); i++)
        remain.insert(i);
    int cnt = 0;
    while (remainGates.size() > 0) {
        idx_t related[numQubits];
        idx_t full = 0;
        memset(related, 0, sizeof(related));
        if (whiteList) {
            for (int i = 0; i < numQubits; i++)
                if (!(whiteList >> i & 1))
                    full |= 1ll << i;
        }
        for (int i = 0; i < numQubits; i++)
            related[i] = required;

        std::vector<int> idx = getGroupOpt(full, related, enableGlobal, localSize, localQubits);
        GateGroup gg;
        for (auto& x: idx)
            gg.addGate(remainGates[x], localQubits, enableGlobal);
        lg.fullGroups.push_back(gg.copyGates()); // TODO: redundant copy?
        lg.relatedQubits |= gg.relatedQubits;
        removeGatesOpt(idx);
        if (whiteList != 0)
            break;
        cnt ++;
        // assert(cnt < 1000);
    }
    return lg;
}

LocalGroup AdvanceCompiler::run(State& state, bool usePerGate, bool useBLAS, int perGateSize, int blasSize, int cuttSize) {
    assert(usePerGate || useBLAS);
    LocalGroup lg;
    lg.relatedQubits = 0;
    int cnt = 0;
    remain.clear();
    for (size_t i = 0; i < remainGates.size(); i++)
        remain.insert(i);
    while (remainGates.size() > 0) {
        idx_t related[numQubits];
        idx_t full;
        auto fillRelated = [this](idx_t related[], const std::vector<int>& layout) {
            for (int i = 0; i < numQubits; i++) {
                related[i] = 0;
                for (int j = 0; j < COALESCE_GLOBAL; j++)
                    related[i] |= ((idx_t) 1) << layout[j];
            }
        };
        auto fillFull = [this](idx_t &full, idx_t forbid) {
            full = forbid;
        };
        GateGroup gg;
        std::vector<int> ggIdx;
        Backend ggBackend;
        idx_t cacheRelated = 0;
        if (usePerGate && useBLAS) {
            // get the gate group for pergate backend
            full = 0;
            fillRelated(related, state.layout);
            cacheRelated = related[0];
            ggIdx = getGroupOpt(full, related, true, perGateSize, -1ll);
            ggBackend = Backend::PerGate;
            double bestEff;
            if (ggIdx.size() == 0) {
                bestEff = 1e10;
            } else {
                std::vector<GateType> tys;
                for (auto& x: ggIdx) tys.push_back(remainGates[x].type);
                bestEff = Evaluator::getInstance() -> perfPerGate(numQubits - globalBit, tys) / ggIdx.size();
                // printf("eff-pergate %f %d %f\n", Evaluator::getInstance() -> perfPerGate(numQubits - globalBit, tys), (int) ggIdx.size(), bestEff);
            }

            for (int matSize = 4; matSize < 8; matSize ++) {
                fillFull(full, blasForbid);
                memset(related, 0, sizeof(related));
                std::vector<int> idx = getGroupOpt(full, related, false, matSize, localQubits | blasForbid);
                if (idx.size() == 0)
                    continue;
                double eff = Evaluator::getInstance() -> perfBLAS(numQubits - globalBit, matSize) / idx.size();
                // printf("eff-blas(%d) %f %d %f\n", matSize, Evaluator::getInstance() -> perfBLAS(numQubits - globalBit, matSize), (int) idx.size(), eff);
                if (eff < bestEff) {
                    ggIdx = idx;
                    ggBackend = Backend::BLAS;
                    bestEff = eff;
                }
            }    
            // printf("GPU_BACKEND %s\n", bestBackend == Backend::BLAS ? "blas" : "pergate");
        } else if (usePerGate && !useBLAS) {
            fillRelated(related, state.layout);
            full = 0;
            cacheRelated = related[0];
            ggIdx = getGroupOpt(full, related, true && enableGlobal, perGateSize, -1ll);
            ggBackend = Backend::PerGate;
        } else if (!usePerGate && useBLAS) {
            memset(related, 0, sizeof(related));
            fillFull(full, blasForbid);
            ggIdx = getGroupOpt(full, related, false, blasSize, localQubits | blasForbid);
            ggBackend = Backend::BLAS;
        } else {
            UNREACHABLE();
        }
        if (ggBackend == Backend::PerGate) {
            for (auto& x: ggIdx)
                gg.addGate(remainGates[x], -1ll, enableGlobal);
#ifdef LOG_EVALUATOR
            Logger::add("perf pergate : %f,", Evaluator::getInstance() -> perfPerGate(numQubits, &gg));
#endif
            gg.relatedQubits |= cacheRelated;
        } else {
            for (auto& x: ggIdx)
                gg.addGate(remainGates[x], localQubits, false);
#ifdef LOG_EVALUATOR
            Logger::add("perf BLAS : %f,", Evaluator::getInstance() -> perfBLAS(numQubits, blasSize));
#endif
        }
        gg.backend = ggBackend;
        state = gg.initState(state, cuttSize);
        removeGatesOpt(ggIdx);
        lg.relatedQubits |= gg.relatedQubits;
        lg.fullGroups.push_back(std::move(gg));
        cnt ++;
        assert(cnt < 1000);
    }
    //Logger::add("local group cnt : %d", cnt);
    return lg;
}

template<int MAX_GATES>
std::vector<int> OneLayerCompiler<MAX_GATES>::getGroupOpt(idx_t full, idx_t related[], bool enableGlobal, int localSize, idx_t localQubits) {
    std::bitset<MAX_GATES> cur[numQubits], new_cur, selected;
    int gateIDs[MAX_GATES], gate_num;
    
    {
        int id = 0;
        for (auto gateID: remain) {
            gateIDs[id++] = gateID;
            if (id == MAX_GATES) break;
        }
        gate_num = id;
    }
    
    int cnt = 0, x;
    for(int id = 0; id < gate_num; id++) {
        x = gateIDs[id];
        if(id % 100 == 0) {
            bool live = false;
            for(int i = 0; i < numQubits; i++)
                if(!(full >> i & 1))
                    live = true;
            if(!live)
                break;
        }
        // printf("gate_num %d x=%d\n", gate_num, x);
        auto& gate = remainGates[x];
        if (gate.isMCGate()) {
            if ((full & gate.encodeQubit) == 0 && (full >> gate.targetQubit & 1) == 0) {
                int t = gate.targetQubit;
                idx_t newRelated = related[t];
                for (auto q: gate.controlQubits) {
                    newRelated |= related[q];
                }
                newRelated = GateGroup::newRelated(newRelated, gate, localQubits, enableGlobal);
                if (bitCount(newRelated) <= localSize) {
                    new_cur = cur[t];
                    for (auto q: gate.controlQubits) {
                        new_cur |= cur[q];
                    }
                    new_cur[id] = 1;
                    for (auto q: gate.controlQubits) {
                        cur[q] = new_cur;
                    }
                    cur[t]= new_cur;
                    related[t] = newRelated;
                    continue;
                }
            }
            full |= 1ll << gate.targetQubit;
            for (auto q: gate.controlQubits) {
                full |= 1ll << q;
            }
        } else if (gate.isTwoQubitGate()) {
            if ((full >> gate.encodeQubit & 1) == 0 && (full >> gate.targetQubit & 1) == 0) {
                int t1 = gate.encodeQubit, t2 = gate.targetQubit;
                idx_t newRelated = related[t1] | related[t2];
                newRelated = GateGroup::newRelated(newRelated, gate, localQubits, enableGlobal);
                if (bitCount(newRelated) <= localSize) {
                    new_cur = cur[t1] | cur[t2];
                    new_cur[id] = 1;
                    cur[t1] = new_cur;
                    cur[t2]= new_cur;
                    related[t1] = related[t2] = newRelated;
                    continue;
                }
            }
            full |= 1ll << gate.encodeQubit;
            full |= 1ll << gate.targetQubit;
        } else if (gate.isControlGate()) {
            if ((full >> gate.controlQubit & 1) == 0 && (full >> gate.targetQubit & 1) == 0) { 
                int c = gate.controlQubit, t = gate.targetQubit;
                idx_t newRelated = related[c] | related[t];
                newRelated = GateGroup::newRelated(newRelated, gate, localQubits, enableGlobal);
                if (bitCount(newRelated) <= localSize) {
                    new_cur = cur[c] | cur[t];
                    new_cur[id] = 1;
                    cur[c] = new_cur;
                    cur[t]= new_cur;
                    related[c] = related[t] = newRelated;
                    continue;
                }
            }
            full |= 1ll << gate.controlQubit;
            full |= 1ll << gate.targetQubit;
        } else {
            if ((full >> gate.targetQubit & 1) == 0) {
                cur[gate.targetQubit][id] = 1;
                related[gate.targetQubit] = GateGroup::newRelated(related[gate.targetQubit], gate, localQubits, enableGlobal);
            }
        }
    }

    bool blocked[numQubits];
    memset(blocked, 0, sizeof(blocked));
    idx_t selectedRelated = 0;
    while (true) {
        int mx = 0, id = -1;
        for (int i = 0; i < numQubits; i++) {
            int count_i = cur[i].count();
            if (!blocked[i] && count_i > mx) {
                if (bitCount(selectedRelated | related[i]) <= localSize) {
                    mx = count_i;
                    id = i;
                } else {
                    blocked[i] = true;
                }
            }
        }
        if (mx == 0)
            break;
        selected |= cur[id];
        selectedRelated |= related[id];
        blocked[id] = true;
        for (int i = 0; i < numQubits; i++)
            if (!blocked[i] && cur[i].any()) {
                if ((related[i] | selectedRelated) == selectedRelated) {
                    selected |= cur[i];
                    blocked[i] = true;
                } else {
                    cur[i] &= ~cur[id];
                }
            }
    }

    if (!enableGlobal) {
        std::vector<int> ret;
        for(int id = 0; id < gate_num; id++) {
            if(selected.test(id))
                ret.push_back(gateIDs[id]);
        }
        return ret;
    }

    memset(blocked, 0, sizeof(blocked));
    cnt = 0;
    for(int id = 0; id < gate_num; id++) {
        x = gateIDs[id];
        cnt ++;
        if (cnt % 100 == 0) {
            bool live = false;
            for (int i = 0; i < numQubits; i++)
                if (!blocked[i])
                    live = true;
            if (!live)
                break;
        }
        if (selected.test(id)) continue;
        auto& g = remainGates[x];
        if (g.isDiagonal() && enableGlobal) {
            if (g.isMCGate()) {
                bool avail = !blocked[g.targetQubit];
                for (auto q: g.controlQubits) {
                    avail &= !blocked[q];
                }
                if (avail) {
                    selected[id] = 1;
                } else {
                    blocked[g.targetQubit] = 1;
                    for (auto q: g.controlQubits) {
                        blocked[q] = 1;
                    }
                }
            } else if (g.isTwoQubitGate()) {
                if (!blocked[g.encodeQubit] && !blocked[g.targetQubit]) {
                    selected[id] = 1;
                } else {
                    blocked[g.encodeQubit] = blocked[g.targetQubit] = 1;
                }
            } else if (g.isControlGate()) {
                if (!blocked[g.controlQubit] && !blocked[g.targetQubit]) {
                    selected[id] = 1;
                } else {
                    blocked[g.controlQubit] = blocked[g.targetQubit] = 1;
                }
            } else {
                if (!blocked[g.targetQubit]) {
                    selected[id] = 1;
                }
            }
        } else {
            if (g.isMCGate()) {
                for (auto q: g.controlQubits) {
                    blocked[q] = 1;
                }
            } else if (g.isTwoQubitGate()) {
                blocked[g.encodeQubit] = 1;
            } else if (g.isControlGate()) {
                blocked[g.controlQubit] = 1;
            }
            blocked[g.targetQubit] = 1;
        }
    }
    std::vector<int> ret;
    for(int id = 0; id < gate_num; id++) {
        if(selected.test(id))
            ret.push_back(gateIDs[id]);
    }
    return ret;
}

ChunkCompiler::ChunkCompiler(int numQubits, int localSize, int chunkSize, const std::vector<Gate> &inputGates):
    OneLayerCompiler(numQubits, inputGates), localSize(localSize), chunkSize(chunkSize) {}

LocalGroup ChunkCompiler::run() {
    std::set<int> locals;
    for (int i = 0; i < localSize; i++)
        locals.insert(i);
    LocalGroup lg;
    GateGroup cur;
    cur.relatedQubits = 0;
    for (size_t i = 0; i < remainGates.size(); i++) {
        if (remainGates[i].isDiagonal() || locals.find(remainGates[i].targetQubit) != locals.end()) {
            cur.addGate(remainGates[i], -1ll, 1);
            continue;
        }
        idx_t newRelated = 0;
        for (auto x: locals)
            newRelated |= ((idx_t) 1) << x;
        cur.relatedQubits = newRelated;
        lg.relatedQubits |= newRelated;
        lg.fullGroups.push_back(std::move(cur));
        cur = GateGroup(); cur.relatedQubits = 0;
        cur.addGate(remainGates[i], -1ll, 1);
        std::set<int> cur_locals;
        for (int j = chunkSize + 1; j < numQubits; j++)
            if (locals.find(j) != locals.end())
                cur_locals.insert(j);
        for (size_t j = i + 1; j < remainGates.size() && cur_locals.size() > 1; j++) {
            if (!remainGates[i].isDiagonal())
                cur_locals.erase(remainGates[i].targetQubit);
        }
        int to_move = *cur_locals.begin();
        locals.erase(to_move);
        locals.insert(remainGates[i].targetQubit);
    }
    idx_t newRelated = 0;
        for (auto x: locals)
            newRelated |= ((idx_t) 1) << x;
    cur.relatedQubits = newRelated;
    lg.relatedQubits |= cur.relatedQubits;
    lg.fullGroups.push_back(std::move(cur));
    return lg;
}

template<int MAX_GATES>
void OneLayerCompiler<MAX_GATES>::removeGatesOpt(const std::vector<int>& remove) {
    for (auto& x: remove)
        remain.erase(x);
    if (remain.empty())
        remainGates.clear();
}