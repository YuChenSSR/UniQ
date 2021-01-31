#!/bin/bash
head=../build/logs/`date +%Y%m%d-%H%M%S`

export CUDA_VISIBLE_DEVICES=0
name=$head-1gpu-o
mkdir -p $name
./check_wrapper.sh $name -DBACKEND=mix -DSHOW_SUMMARY=on -DSHOW_SCHEDULE=off -DUSE_DOUBLE=on -DEVALUATOR_PREPROCESS=on -DENABLE_OVERLAP=on 2>&1 | tee $name/std.out
name1=$name

export CUDA_VISIBLE_DEVICES=0,1
name=$head-2gpu-o
mkdir -p $name
./check_wrapper.sh $name -DBACKEND=mix -DSHOW_SUMMARY=on -DSHOW_SCHEDULE=off -DUSE_DOUBLE=on -DEVALUATOR_PREPROCESS=on -DENABLE_OVERLAP=on 2>&1 | tee $name/std.out
name2=$name

export CUDA_VISIBLE_DEVICES=0,1,2,3
name=$head-4gpu-o
mkdir -p $name
./check_wrapper.sh $name -DBACKEND=mix -DSHOW_SUMMARY=on -DSHOW_SCHEDULE=off -DUSE_DOUBLE=on -DEVALUATOR_PREPROCESS=on  -DENABLE_OVERLAP=on 2>&1 | tee $name/std.out
name3=$name

export CUDA_VISIBLE_DEVICES=0
name=$head-1gpu-s
mkdir -p $name
./check_wrapper.sh $name -DBACKEND=mix -DSHOW_SUMMARY=on -DSHOW_SCHEDULE=off -DUSE_DOUBLE=on -DEVALUATOR_PREPROCESS=on -DENABLE_OVERLAP=off 2>&1 | tee $name/std.out
name1=$name

export CUDA_VISIBLE_DEVICES=0,1
name=$head-2gpu-s
mkdir -p $name
./check_wrapper.sh $name -DBACKEND=mix -DSHOW_SUMMARY=on -DSHOW_SCHEDULE=off -DUSE_DOUBLE=on -DEVALUATOR_PREPROCESS=on -DENABLE_OVERLAP=off 2>&1 | tee $name/std.out
name2=$name

export CUDA_VISIBLE_DEVICES=0,1,2,3
name=$head-4gpu-s
mkdir -p $name
./check_wrapper.sh $name -DBACKEND=mix -DSHOW_SUMMARY=on -DSHOW_SCHEDULE=off -DUSE_DOUBLE=on -DEVALUATOR_PREPROCESS=on -DENABLE_OVERLAP=off 2>&1 | tee $name/std.out
name3=$name


grep -r "Time Cost" $head-*/*.log
