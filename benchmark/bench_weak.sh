#!/bin/bash
source ../scripts/init.sh -DGPU_BACKEND=mix -DSHOW_SUMMARY=on -DSHOW_SCHEDULE=off -DMICRO_BENCH=on -DUSE_DOUBLE=on -DEVALUATOR_PREPROCESS=on -DUSE_MPI=off
LOG=../benchmark/logs
CUDA_VISIBLE_DEVICES=0 ./main ../tests/input/basis_change_24.qasm 2>&1 | tee $LOG/weak.log
CUDA_VISIBLE_DEVICES=0,1 ./main ../tests/input/basis_change_24.qasm 2>&1 | tee -a $LOG/weak.log
CUDA_VISIBLE_DEVICES=0,1,2,3 ./main ../tests/input/basis_change_24.qasm 2>&1 | tee -a $LOG/weak.log
CUDA_VISIBLE_DEVICES=0 ./main ../tests/input/basis_change_25.qasm 2>&1 | tee -a $LOG/weak.log
CUDA_VISIBLE_DEVICES=0,1 ./main ../tests/input/basis_change_25.qasm 2>&1 | tee -a $LOG/weak.log
CUDA_VISIBLE_DEVICES=0,1,2,3 ./main ../tests/input/basis_change_25.qasm 2>&1 | tee -a $LOG/weak.log
CUDA_VISIBLE_DEVICES=0 ./main ../tests/input/basis_change_26.qasm 2>&1 | tee -a $LOG/weak.log
CUDA_VISIBLE_DEVICES=0,1 ./main ../tests/input/basis_change_26.qasm 2>&1 | tee -a $LOG/weak.log
CUDA_VISIBLE_DEVICES=0,1,2,3 ./main ../tests/input/basis_change_26.qasm 2>&1 | tee -a $LOG/weak.log
CUDA_VISIBLE_DEVICES=0 ./main ../tests/input/basis_change_27.qasm 2>&1 | tee -a $LOG/weak.log
CUDA_VISIBLE_DEVICES=0,1 ./main ../tests/input/basis_change_27.qasm 2>&1 | tee -a $LOG/weak.log
CUDA_VISIBLE_DEVICES=0,1,2,3 ./main ../tests/input/basis_change_27.qasm 2>&1 | tee -a $LOG/weak.log
CUDA_VISIBLE_DEVICES=0 ./main ../tests/input/basis_change_28.qasm 2>&1 | tee -a $LOG/weak.log
CUDA_VISIBLE_DEVICES=0,1 ./main ../tests/input/basis_change_28.qasm 2>&1 | tee -a $LOG/weak.log
CUDA_VISIBLE_DEVICES=0,1,2,3 ./main ../tests/input/basis_change_28.qasm 2>&1 | tee -a $LOG/weak.log
CUDA_VISIBLE_DEVICES=0,1 ./main ../tests/input/basis_change_29.qasm 2>&1 | tee -a $LOG/weak.log
CUDA_VISIBLE_DEVICES=0,1,2,3 ./main ../tests/input/basis_change_29.qasm 2>&1 | tee -a $LOG/weak.log
CUDA_VISIBLE_DEVICES=0,1,2,3 ./main ../tests/input/basis_change_30.qasm 2>&1 | tee -a $LOG/weak.log

grep -r "Logger" $LOG/weak.log | tee $LOG/weak_summary.log