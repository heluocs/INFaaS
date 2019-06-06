#!/bin/bash

set -e

function check_quit () {
	if [[ "$1" == "QUIT" ]]; then
    echo "Quitting..."
		exit 0
	fi
}

if [ $# -lt 4 ]; then
  echo "Usage: ./profile_model.sh <frozen-model> <accuracy> <dataset> <task> [<cpus>]"
  echo "<cpus> is optional, and will only be used if framework is tensorflow-cpu or pytorch"
  exit 1
fi

declare -a BATCH=(
1
4
8
)

FROZEN_MODEL=$1
ACCURACY=$2
DATASET=$3
TASK=$4
NUM_CPUS=${5:-1}

TASK=`echo "$TASK" | tr '[:upper:]' '[:lower:]'`
# INFaaS currently supports classification and translation
if [[ "$TASK" != "classification" && \
      "$TASK" != "translation" ]]; then
  echo "INFaaS currently supports the following tasks: classification and translation"
  exit 1
fi

TEMPLATE_FILE="model_profile.config.template"
PROFILEDB="/tmp/trtmodels"
INFAAS_MAX_BATCH=128
TRTPROFILEWINDOW=1000
TRTSERVERNAME="trt_server"
TFSERVINGNAME="tensorflow_serving"
PYTORCHNAME="pytorch_serving"
SCRIPT_DIR=$(dirname $(readlink -f $0))
TEST_IMAGE=${SCRIPT_DIR}"/../../data/mug.jpg"
MAX_TRY=500

# Check that file exists before proceeding
if [ ! -f $FROZEN_MODEL ]; then
  echo $FROZEN_MODEL" does not exist or is an invalid path."
  exit 1
fi

echo "=============INFaaS Profiler============="
echo "===Inputted Parameters==="
echo "Model: "${FROZEN_MODEL}
echo "Accuracy: "${ACCURACY}
echo "Dataset: "${DATASET}
echo "Task: "${TASK}
echo "Number of CPUs: "${NUM_CPUS}
echo "=== ==="

echo "The profiler will first ask some questions to best profile the model"
echo "At any point, if you wish to quit, enter QUIT"
echo "----"
echo

# Get compressed size
comp_size=`stat --printf="%s" ${FROZEN_MODEL}`

# Attempt to get framework and parent name
base_file=$(basename ${FROZEN_MODEL})
par_mod=$(echo "${base_file}" | cut -f 1 -d '.')
extension=$(echo "${base_file}" | cut -f 2 -d '.')

# Name of parent model
echo -n "The profiler has detected the name of the parent model to be "$par_mod". Is this correct? [Y/n] "
read yn_resp
check_quit "$yn_resp"
if [[ $yn_resp == N ]] || [[ $yn_resp == n ]]; then
  echo -n "What is the name of the parent model? "
  read par_mod
  check_quit "$par_mod"
fi

par_mod=`echo "$par_mod" | tr '[:upper:]' '[:lower:]'`
var_mod="" # Will be set later, depending on the framework
max_batch=$INFAAS_MAX_BATCH

# Framework
framework="dummy"
if [[ $extension == "trt" ]] || [[ $extension == "plan" ]]; then
  framework="tensorrt"
elif [[ $extension == "pb" ]]; then
  framework="tensorflow-cpu"
elif [[ $extension == "pt" ]]; then
  framework="pytorch"
elif [[ $extension == "netdef" ]]; then
  framework="caffe2"
fi

if [[ $framework == "dummy" ]]; then
  echo -n "What is the model's framwork? Currently, INFaaS supports TensorRT, TensorFlow, Caffe2, and PyTorch. "
  read framework
  check_quit "$framework"
else
  echo -n "The profiler has detected the model's framework to be "$framework". Is this correct? [Y/n] "
  read yn_resp
  check_quit "$yn_resp"
  if [[ $yn_resp == N ]] || [[ $yn_resp == n ]]; then
    echo -n "What is the model's framework? "
    read framework 
    check_quit "$framework"
  fi
fi

framework=`echo "$framework" | tr '[:upper:]' '[:lower:]'`

TENSORRT_DIR=""
TRANSLATION_DIR=""
PYTORCH_DIR=""
if [[ $framework == "tensorrt" ]] || [[ $framework == "tensorflow-gpu" ]] || \
   [[ $framework == "caffe2" ]]; then
  echo -n "Where is the root directory for this model? "
  echo -n "(It should have a config.pbtxt and the model, named model.plan, in a version directory) "
  read TENSORRT_DIR
  check_quit "$TENSORRT_DIR"

  # Now set var_mod and max_batch
  var_mod=$(basename ${TENSORRT_DIR})
  max_batch=`grep "max_batch_size" ${TENSORRT_DIR}/config.pbtxt | cut -d' ' -f2`

elif [[ $framework == "tensorflow-cpu" ]] && [[ $TASK == "translation" ]]; then
  echo -n "Where is the root directory for this model? "
  read TRANSLATION_DIR
  check_quit "$TRANSLATION_DIR"
elif [[ $framework == "pytorch" ]]; then
  echo -n "Where is the root directory for this model? "
  read PYTORCH_DIR 
  check_quit "$PYTORCH_DIR"
fi

# Now profile the model to determine its load and inference latencies
# FOR NOW...
### If it's a pytorch model, we will profile only on CPU.
### If it's a tensorflow model, we will profile on both CPU and GPU.

# Install bc if needed
if command -v bc >/dev/null; then
  echo "[LOG]: bc detected"
else
  sudo apt -y install bc
fi

# Install convert if needed
if command -v convert >/dev/null; then
  echo "[LOG]: convert detected"
else
  sudo apt -y install imagemagick
fi

# If task is classification, ask what the dimensions of the input are
im_dim="224"
b64image=""
if [[ $TASK == "classification" ]]; then
    echo -n "What is the dimension of your model's input (e.g., 224)? "
    read im_dim 
    check_quit "$im_dim"

    # Create and convert test image
  if [[ $framework == "pytorch"  ]] || [[ $framework == "tensorflow-cpu" ]]; then
    convert -resize ${im_dim}x${im_dim}! ${TEST_IMAGE} resized_img.jpg
    b64image=`./img_to_base64.py resized_img.jpg`
    b64image=`echo ${b64image} | cut -d "'" -f 2`
  fi
fi

load_time=0
inftimeb1=0
inftimeb4=0
inftimeb8=0
max_mem=0

# This script assumes the latest docker containers for the TensorRT Server, TensorFlow Serving,
# and INFaaS PyTorch are already downloaded
#
# docker pull nvcr.io/nvidia/tensorrtserver:19.03-py3
# docker pull tensorflow/serving
# docker pull qianl15/infaaspytorch:latest
### TENSORRT or TENSORFLOW-GPU
if [[ $framework == "tensorrt" ]] || [[ $framework == "tensorflow-gpu" ]] || \
   [[ $framework == "caffe2" ]]; then
  # Clear previous modeldb
  sudo rm -rf ${PROFILEDB}/*

  # Give server a second to stabilize
  sleep 1

  # Start the TensorRT Server if necessary
  if [ ! "$(docker ps -a | grep ${TRTSERVERNAME})" ]; then
    nvidia-docker run -d --rm --shm-size=1g --ulimit memlock=-1 \
      --name ${TRTSERVERNAME} \
      --ulimit stack=67108864 -p8000:8000 -p8001:8001 -p8002:8002 \
      -v${PROFILEDB}:/models \
      nvcr.io/nvidia/tensorrtserver:19.03-py3 trtserver \
      --model-store='/models' \
      --strict-model-config=false \
      --tf-gpu-memory-fraction=0.5 \
      --repository-poll-secs=1

    # Wait until the server is up
    ready_state=""
    cnt=0
    while [[ -z "${ready_state}" ]]; do
      curl -s localhost:8000/api/status/ | grep -q "SERVER_READY" && ready_state="ready"
      cnt=$[$cnt+1]
      if [[ $cnt -eq ${MAX_TRY} ]]; then
        echo "TensorRT server failed to start"
        exit 1
      fi
      sleep 1 # avoid busy looping
    done
  fi

  # Baseline memory
	base_mem=$(nvidia-smi --query-gpu=memory.used --format=csv|grep -v memory|awk '{print $1}')

  # Copy model into directory and time how long it takes it to be loaded
  start=`date +%s.%N`
  sudo cp -rf ${TENSORRT_DIR} ${PROFILEDB}
  ready_state=""
  while [[ -z "${ready_state}" ]]; do
    curl -s localhost:8000/api/status/${var_mod} | grep -q "MODEL_READY" && ready_state="ready"
    sleep .01 # avoid busy looping, but also want accurate load latency measurement
  done
  finish=`date +%s.%N`
  load_time=$( echo "$finish - $start" | bc -l )
  load_time=$( echo "$load_time * 1000" | bc -l )
  echo "Load time was: "$load_time

	curr_mem=$(nvidia-smi --query-gpu=memory.used --format=csv|grep -v memory|awk '{print $1}')
  max_mem=$( echo "$curr_mem - $base_mem" | bc -l )
  max_mem=$( echo "$max_mem * 1.04858 * 1000000" | bc -l )

  # TensorRT Server averages for us. Run one query to "warm it up".
  $SCRIPT_DIR/../../build/bin/trtis_perf_client -b1 -t1 -p${TRTPROFILEWINDOW} -m${var_mod} > /dev/null 2>&1 || true

  # Get batch 1
  $SCRIPT_DIR/../../build/bin/trtis_perf_client -b1 -t1 -p${TRTPROFILEWINDOW} -m${var_mod} > temp.out
  inftimeb1=`grep "Avg latency" temp.out | awk -v N=3 '{print $3}'`
  inftimeb1=$( echo "$inftimeb1 / 1000" | bc -l ) # us -> ms

  if [ $max_batch == 1 ]; then
    inftimeb4=0
    inftimeb8=0
  elif [ $max_batch -le 4 ]; then
    # Get batch 4
    $SCRIPT_DIR/../../build/bin/trtis_perf_client -b4 -t1 -p${TRTPROFILEWINDOW} -m${var_mod} > temp.out
    inftimeb4=`grep "Avg latency" temp.out | awk -v N=3 '{print $3}'`
    inftimeb4=$( echo "$inftimeb4 / 1000" | bc -l ) # us -> ms
    inftimeb8=0
  else
    # Get batch 4
    $SCRIPT_DIR/../../build/bin/trtis_perf_client -b4 -t1 -p${TRTPROFILEWINDOW} -m${var_mod} > temp.out
    inftimeb4=`grep "Avg latency" temp.out | awk -v N=3 '{print $3}'`
    inftimeb4=$( echo "$inftimeb4 / 1000" | bc -l ) # us -> ms

    # Get batch 8
    $SCRIPT_DIR/../../build/bin/trtis_perf_client -b8 -t1 -p${TRTPROFILEWINDOW} -m${var_mod} > temp.out
    inftimeb8=`grep "Avg latency" temp.out | awk -v N=3 '{print $3}'`
    inftimeb8=$( echo "$inftimeb8/ 1000" | bc -l ) # us -> ms
  fi

  echo "Inference time (B1): "$inftimeb1
  echo "Inference time (B4): "$inftimeb4
  echo "Inference time (B8): "$inftimeb8

  echo "Memory: "${max_mem}" bytes"

  ### Cleanup
  # Remove temporary file
  rm -rf temp.out
 
  # Remove test model
  sudo rm -rf ${PROFILEDB}/*

### PYTORCH
elif [[ $framework == "pytorch" ]]; then
  rm -rf /tmp/model/
  mkdir -p /tmp/model
  cp -rf ${PYTORCH_DIR} /tmp/model/

  # Start container in the background
  if [ ! "$(docker ps -q -f name=${PYTORCHNAME})" ]; then
    if [ "$(docker ps -aq -f status=exited -f name=${PYTORCHNAME})" ]; then
      docker rm ${PYTORCHNAME} > /dev/null
    fi
  else
    docker kill ${PYTORCHNAME} > /dev/null
  fi

  docker run -d --rm -p 8501:8501 \
    --name=${PYTORCHNAME} \
    --cpus ${NUM_CPUS} \
    --ipc=host \
    -v/tmp/model:/tmp/model \
    qianl15/infaaspytorch:latest \
    /workspace/container_start.sh pytorch_container.py ${im_dim} ${par_mod} 8501 \
    > /dev/null

  # See how long it takes to send request to model (load time)
  start=`date +%s.%N`
  cnt=0
  ready_state=""
  while [[ -z "${ready_state}" ]]; do
    python3 pytorch_query.py resized_img.jpg 8501 1 2> /dev/null && ready_state="ready"

    cnt=$[$cnt+1]
    if [[ $cnt == ${MAX_TRY} ]]; then
      echo "Failure to profile model: could not reach serving container"
      exit 1
    fi
    sleep .01 # avoid busy looping, but also want accurate load latency measurement
  done
  finish=`date +%s.%N`
  load_time=$( echo "$finish - $start" | bc -l )
  load_time=$( echo "$load_time * 1000" | bc -l )
  echo "Load time: "$load_time"ms"

  # Now time a single request. Repeat 3 times and take the average
  for b in "${BATCH[@]}"; do
    for i in {1..3}; do
      # If it's the second run, collect memory information
      if [[ $b == 8 ]] && [[ $i == 2 ]]; then
        python3 pytorch_query.py resized_img.jpg 8501 ${b} > temp.out &

        while true; do
          if ! pgrep "python3" > /dev/null 2>&1; then
            break
          fi
          pid=`pgrep python3`
          map=`sudo pmap -x ${pid}`
          curr_mem=`echo ${map} | tr ' ' '\n' | tail -2 | head -1`
          [ ${curr_mem} -gt ${max_mem} ] && max_mem=${curr_mem}
          sleep .05
        done
        max_mem=$( echo "$max_mem * 1000" | bc -l ) # pmap reports kB, want B
        echo "Memory: "${max_mem}" bytes"
      else
        python3 pytorch_query.py resized_img.jpg 8501 ${b} > temp.out
      fi
      curr_run=`cat temp.out`
      if [[ $b == 1 ]]; then
        inftimeb1=$( echo "$curr_run + $inftimeb1" | bc -l )
      elif [[ $b == 4 ]]; then
        inftimeb4=$( echo "$curr_run + $inftimeb4" | bc -l )
      elif [[ $b == 8 ]]; then
        inftimeb8=$( echo "$curr_run + $inftimeb8" | bc -l )
      fi

    done
  done
  inftimeb1=$( echo "$inftimeb1 / 3 * 1000" | bc -l )
  inftimeb4=$( echo "$inftimeb4 / 3 * 1000" | bc -l )
  inftimeb8=$( echo "$inftimeb8 / 3 * 1000" | bc -l )
  echo "Inference time (B1): "$inftimeb1
  echo "Inference time (B4): "$inftimeb4
  echo "Inference time (B8): "$inftimeb8

  ### Cleanup
  # Remove temporary file
  rm -rf temp.out

  # Kill container
  docker kill ${PYTORCHNAME} > /dev/null

  # Remove test image
  rm resized_img.jpg
  
  # Remove test directory
  rm -rf /tmp/model

### TENSORFLOW-CPU -> classification
elif [[ $framework == "tensorflow-cpu" ]] && [[ $TASK == "classification" ]]; then
  rm -rf ${par_mod}
  mkdir -p ${par_mod}"/000123"
  mkdir ${par_mod}"/000123/variables"
  cp ${FROZEN_MODEL} ${par_mod}"/000123"

  # Start container in the background
  if [ ! "$(docker ps -q -f name=${TFSERVINGNAME})" ]; then
    if [ "$(docker ps -aq -f status=exited -f name=${TFSERVINGNAME})" ]; then
      docker rm ${TFSERVINGNAME} > /dev/null
    fi
  else
    docker kill ${TFSERVINGNAME} > /dev/null
  fi

  docker run -d --rm -p 8501:8501 \
   --name ${TFSERVINGNAME} \
   --cpus ${NUM_CPUS} \
   --mount type=bind,source=${SCRIPT_DIR}/${par_mod},target=/models/${par_mod} \
   --mount type=bind,source=${SCRIPT_DIR}/batching_parameters.txt,target=/models/batching_parameters.txt \
   -e MODEL_NAME=${par_mod} \
   -t tensorflow/serving \
      --enable_batching=true \
      --batching_parameters_file=/models/batching_parameters.txt > /dev/null

  # See how long it takes to send request to model (load time)
  start=`date +%s.%N`
  cnt=0
  ready_state=""
  while [[ -z "${ready_state}" ]]; do
    curl -s -X POST http://localhost:8501/v1/models/${par_mod}:predict -d @<(
      printf '{"instances": [{"b64": "'
      echo $b64image
      printf '"}]}'
    ) > temp.out ||:

    grep -q "predictions" temp.out && ready_state="ready"
    cnt=$[$cnt+1]
    if [[ $cnt == ${MAX_TRY} ]]; then
      echo "Failure to profile model: could not reach serving container"
      exit 1
    fi
    sleep .01 # avoid busy looping, but also want accurate load latency measurement
  done
  finish=`date +%s.%N`
  load_time=$( echo "$finish - $start" | bc -l )
  load_time=$( echo "$load_time * 1000" | bc -l )
  echo "Load time: "$load_time"ms"

  rm -rf temp.out

  # Now time a single request. Repeat 3 times and take the average
  for b in "${BATCH[@]}"; do
    for i in {1..3}; do
      # If it's the second run, collect memory information
      if [[ $b == 8 ]] && [[ $i == 2 ]]; then
        for num_b in $( eval echo {1..$b} ); do
          if [[ $num_b -lt $b ]]; then
             curl -s -X POST http://localhost:8501/v1/models/${par_mod}:predict -d @<(
              printf '{"instances": [{"b64": "'
              echo $b64image
              printf '"}]}'
            ) > /dev/null &
          else
            /usr/bin/time -v -o temp.out curl -s -X POST http://localhost:8501/v1/models/${par_mod}:predict -d @<(
              printf '{"instances": [{"b64": "'
              echo $b64image
              printf '"}]}'
            ) > /dev/null &
          fi
        done

        docker_pid=`docker inspect --format="{{.State.Pid}}" ${TFSERVINGNAME}`
        # Probe for 30 seconds
        for p in {1..3000}; do
          map=`sudo pmap -x ${docker_pid}`
          curr_mem=`echo ${map} | tr ' ' '\n' | tail -2 | head -1`
          [ ${curr_mem} -gt ${max_mem} ] && max_mem=${curr_mem}
          sleep .01
        done
        max_mem=$( echo "$max_mem * 1000" | bc -l ) # pmap reports kB, want B
        echo "Memory: "${max_mem}" bytes"
      else
        for num_b in $( eval echo {1..$b} ); do
          if [[ $num_b -lt $b ]]; then
             curl -s -X POST http://localhost:8501/v1/models/${par_mod}:predict -d @<(
              printf '{"instances": [{"b64": "'
              echo $b64image
              printf '"}]}'
            ) > /dev/null &
          else
            /usr/bin/time -v -o temp.out curl -s -X POST http://localhost:8501/v1/models/${par_mod}:predict -d @<(
              printf '{"instances": [{"b64": "'
              echo $b64image
              printf '"}]}'
            ) > /dev/null
          fi
        done
      fi
      curr_run=`grep "Elapsed" temp.out | awk 'NF>1{print $NF}' | cut -d: -f2`
      if [[ $b == 1 ]]; then
        inftimeb1=$( echo "$curr_run + $inftimeb1" | bc -l )
      elif [[ $b == 4 ]]; then
        inftimeb4=$( echo "$curr_run + $inftimeb4" | bc -l )
      elif [[ $b == 8 ]]; then
        inftimeb8=$( echo "$curr_run + $inftimeb8" | bc -l )
      fi
    done
  done
  inftimeb1=$( echo "$inftimeb1 / 3 * 1000" | bc -l )
  inftimeb4=$( echo "$inftimeb4 / 3 * 1000" | bc -l )
  inftimeb8=$( echo "$inftimeb8 / 3 * 1000" | bc -l )
  echo "Inference time (B1): "$inftimeb1
  echo "Inference time (B4): "$inftimeb4
  echo "Inference time (B8): "$inftimeb8

  ### Cleanup
  # Remove temporary file
  rm -rf temp.out

  # Kill container
  docker kill ${TFSERVINGNAME} > /dev/null

  # Remove test image
  rm resized_img.jpg
  
  # Remove test directory
  rm -rf ${par_mod}

### TENSORFLOW-CPU -> translation
elif [[ $framework == "tensorflow-cpu" ]] && [[ $TASK == "translation" ]]; then
  rm -rf ${par_mod}
  #mkdir -p ${par_mod}"/000123"
  #mkdir ${par_mod}"/000123/variables"
  cp -rf ${TRANSLATION_DIR} ${par_mod}

  # Start container in the background
  if [ ! "$(docker ps -q -f name=${TFSERVINGNAME})" ]; then
    if [ "$(docker ps -aq -f status=exited -f name=${TFSERVINGNAME})" ]; then
      docker rm ${TFSERVINGNAME} > /dev/null
    fi
  else
    docker kill ${TFSERVINGNAME} > /dev/null
  fi

  docker run -d --rm -p 8501:8501 \
   --name ${TFSERVINGNAME} \
   --cpus ${NUM_CPUS} \
   --mount type=bind,source=${SCRIPT_DIR}/${par_mod},target=/models/${par_mod} \
   --mount type=bind,source=${SCRIPT_DIR}/batching_parameters.txt,target=/models/batching_parameters.txt \
   -e MODEL_NAME=${par_mod} \
   -t tensorflow/serving \
      --enable_batching=true \
      --batching_parameters_file=/models/batching_parameters.txt > /dev/null

  # Stupid "Lower One Eighth Block" space marker
  space_marker=`echo -ne '\xE2\x96\x81'`

  # See how long it takes to send request to model (load time)
  start=`date +%s.%N`
  cnt=0
  ready_state=""
  while [[ -z "${ready_state}" ]]; do
    curl -s -d '{"instances": [{"tokens": ["'${space_marker}'dog"], "length": 1}]}'  -X POST http://localhost:8501/v1/models/${par_mod}:predict > temp.out ||:

    grep -q "predictions" temp.out && ready_state="ready"
    cnt=$[$cnt+1]
    if [[ $cnt == ${MAX_TRY} ]]; then
      echo "Failure to profile model: could not reach serving container"
      exit 1
    fi
    sleep .01 # avoid busy looping, but also want accurate load latency measurement
  done
  finish=`date +%s.%N`
  load_time=$( echo "$finish - $start" | bc -l )
  load_time=$( echo "$load_time * 1000" | bc -l )
  echo "Load time: "$load_time"ms"

  rm -rf temp.out

  # Now time a single request. Repeat 3 times and take the average
  for b in "${BATCH[@]}"; do
    for i in {1..3}; do
      # If it's the second run, collect memory information
      if [[ $b == 8 ]] && [[ $i == 2 ]]; then
        for num_b in $( eval echo {1..$b} ); do
          if [[ $num_b -lt $b ]]; then
            curl -s -d '{"instances": [{"tokens": ["'${space_marker}'dog"], "length": 1}]}'  -X POST http://localhost:8501/v1/models/${par_mod}:predict > /dev/null &
          else
            /usr/bin/time -v -o temp.out curl -s -d '{"instances": [{"tokens": ["'${space_marker}'dog"], "length": 1}]}'  -X POST http://localhost:8501/v1/models/${par_mod}:predict > /dev/null &
          fi
        done

        docker_pid=`docker inspect --format="{{.State.Pid}}" ${TFSERVINGNAME}`
        # Probe for 10 seconds
        for p in {1..1000}; do
          map=`sudo pmap -x ${docker_pid}`
          curr_mem=`echo ${map} | tr ' ' '\n' | tail -2 | head -1`
          [ ${curr_mem} -gt ${max_mem} ] && max_mem=${curr_mem}
          sleep .01
        done
        max_mem=$( echo "$max_mem * 1000" | bc -l ) # pmap reports kB, want B
        echo "Memory: "${max_mem}" bytes"
      else
        for num_b in $( eval echo {1..$b} ); do
          if [[ $num_b -lt $b ]]; then
            curl -s -d '{"instances": [{"tokens": ["'${space_marker}'dog"], "length": 1}]}'  -X POST http://localhost:8501/v1/models/${par_mod}:predict > /dev/null &
          else
            /usr/bin/time -v -o temp.out curl -s -d '{"instances": [{"tokens": ["'${space_marker}'dog"], "length": 1}]}'  -X POST http://localhost:8501/v1/models/${par_mod}:predict > /dev/null
          fi
        done
      fi
      curr_run=`grep "Elapsed" temp.out | awk 'NF>1{print $NF}' | cut -d: -f2`
      if [[ $b == 1 ]]; then
        inftimeb1=$( echo "$curr_run + $inftimeb1" | bc -l )
      elif [[ $b == 4 ]]; then
        inftimeb4=$( echo "$curr_run + $inftimeb4" | bc -l )
      elif [[ $b == 8 ]]; then
        inftimeb8=$( echo "$curr_run + $inftimeb8" | bc -l )
      fi
    done
  done
  inftimeb1=$( echo "$inftimeb1 / 3 * 1000" | bc -l )
  inftimeb4=$( echo "$inftimeb4 / 3 * 1000" | bc -l )
  inftimeb8=$( echo "$inftimeb8 / 3 * 1000" | bc -l )
  echo "Inference time (B1): "$inftimeb1
  echo "Inference time (B4): "$inftimeb4
  echo "Inference time (B8): "$inftimeb8

  ### Cleanup
  # Remove temporary file
  rm -rf temp.out

  # Kill container
  docker kill ${TFSERVINGNAME} > /dev/null

  # Remove test directory
  rm -rf ${par_mod}
fi

# Write model out to configuration file
model_config_name=""
if [[ $framework == "tensorflow-cpu" ]] || [[ $framework == "pytorch" ]]; then
  model_config_name=${par_mod}"_"${framework}"_"${NUM_CPUS}
  var_mod=${model_config_name}
elif [[ $framework == "tensorrt" ]] || [[ $framework == "tensorflow-gpu" ]] || \
     [[ $framework == "caffe2" ]]; then
  model_config_name=${var_mod}
fi

model_config_name=${model_config_name}".config"

cp ${TEMPLATE_FILE} ${model_config_name}

# Add parent name
sed -i "s|<PARNAME>|$par_mod|g" ${model_config_name}

# Add variant name
sed -i "s|<VARNAME>|$var_mod|g" ${model_config_name}

# Add dataset
sed -i "s|<DATASET>|$DATASET|g" ${model_config_name}

# Add input dimension 
sed -i "s|<INPUTDIM>|$im_dim|g" ${model_config_name}

# Add task
sed -i "s|<TASK>|$TASK|g" ${model_config_name}

# Add framework
sed -i "s|<FRAMEWORK>|$framework|g" ${model_config_name}

# Add max batch
sed -i "s|<MAXBATCH>|$max_batch|g" ${model_config_name}

# Add load latency
sed -i "s|<LOADLAT>|$load_time|g" ${model_config_name}

# Add inference latency (B1)
sed -i "s|<INFLATB1>|$inftimeb1|g" ${model_config_name}

# Add inference latency (B4)
sed -i "s|<INFLATB4>|$inftimeb4|g" ${model_config_name}

# Add inference latency (B8)
sed -i "s|<INFLATB8>|$inftimeb8|g" ${model_config_name}

# Add accuracy
sed -i "s|<ACCURACY>|$ACCURACY|g" ${model_config_name}

# Add max memory
sed -i "s|<PEAKMEMORY>|$max_mem|g" ${model_config_name}

# Add compressed size
sed -i "s|<COMPSIZE>|$comp_size|g" ${model_config_name}

# Add frozen model filename
sed -i "s|<FILENAME>|$base_file|g" ${model_config_name}

echo -n "Your model has been successfully profiled. "
echo "The configuration is available in "${model_config_name}

exit 0

