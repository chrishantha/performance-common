#!/bin/bash -e
# Copyright (c) 2018, WSO2 Inc. (http://wso2.org) All Rights Reserved.
#
# WSO2 Inc. licenses this file to you under the Apache License,
# Version 2.0 (the "License"); you may not use this file except
# in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.
#
# ----------------------------------------------------------------------------
# Run performance tests on AWS CloudFormation stacks.
# ----------------------------------------------------------------------------

# Source common script
script_dir=$(dirname "$0")
script_dir=$(realpath $script_dir)
. $script_dir/../common/common.sh

# Check commands
check_command bc
check_command aws
check_command unzip
check_command zip
check_command jq
check_command python
check_command ts

script_start_time=$(date +%s)
performance_scripts_distribution=""
default_results_dir="results-$(date +%Y%m%d%H%M%S)"
results_dir="$default_results_dir"
scripts_distribution=""
key_file=""
jmeter_distribution=""
oracle_jdk_distribution=""
stack_name_prefix=""
key_name=""
s3_bucket_name=""
s3_bucket_region=""
jmeter_client_ec2_instance_type=""
jmeter_server_ec2_instance_type=""
netty_ec2_instance_type=""
test_script=""
# GCViewer Jar file to analyze GC logs
gcviewer_jar_path=""
default_minimum_stack_creation_wait_time=5
minimum_stack_creation_wait_time=$default_minimum_stack_creation_wait_time
default_number_of_stacks=1
number_of_stacks=$default_number_of_stacks
default_parallel_parameter_option="u"
parallel_parameter_option="$default_parallel_parameter_option"
ALLOWED_OPTIONS="ubsm"

function usage() {
    echo ""
    echo "Usage: "
    echo "${script_name:-$0} -f <performance_scripts_distribution> [-d <results_dir>] -k <key_file> -n <key_name>"
    echo "   -j <jmeter_distribution> -o <oracle_jdk_distribution> -g <gcviewer_jar_path>"
    echo "   -s <stack_name_prefix> -b <s3_bucket_name> -r <s3_bucket_region>"
    echo "   -J <jmeter_client_ec2_instance_type> -S <jmeter_server_ec2_instance_type>"
    echo "   -N <netty_ec2_instance_type> "
    if function_exists usageCommand; then
        echo "   $(usageCommand)"
    fi
    echo "   [-t <number_of_stacks>] [-p <parallel_parameter_option>] [-w <minimum_stack_creation_wait_time>]"
    echo "   [-h] -- [run_performance_tests_options]"
    echo ""
    echo "-f: Distribution containing the scripts to run performance tests."
    echo "-d: The results directory. Default value is a directory with current time. For example, $default_results_dir."
    echo "-k: Amazon EC2 Key File. Amazon EC2 Key Name must match with this file name."
    echo "-n: Amazon EC2 Key Name."
    echo "-j: Apache JMeter (tgz) distribution."
    echo "-o: Oracle JDK distribution."
    echo "-g: Path of GCViewer Jar file, which will be used to analyze GC logs."
    echo "-s: The Amazon CloudFormation Stack Name Prefix."
    echo "-b: Amazon S3 Bucket Name."
    echo "-r: Amazon S3 Bucket Region."
    echo "-J: Amazon EC2 Instance Type for JMeter Client."
    echo "-S: Amazon EC2 Instance Type for JMeter Server."
    echo "-N: Amazon EC2 Instance Type for Netty (Backend) Service."
    if function_exists usageHelp; then
        echo "$(usageHelp)"
    fi
    echo "-t: Number of stacks to create. Default: $default_number_of_stacks."
    echo "-p: Parameter option of the test script, which will be used to run tests in parallel."
    echo "    Default: $default_parallel_parameter_option. Allowed option characters: $ALLOWED_OPTIONS."
    echo "-w: The minimum time to wait in minutes before polling for cloudformation stack's CREATE_COMPLETE status."
    echo "    Default: $default_minimum_stack_creation_wait_time."
    echo "-h: Display this help and exit."
    echo "[-m: Test script to run.]"
    echo ""
}

while getopts "f:d:k:n:j:o:g:s:b:r:J:S:N:t:p:w:h:m" opts; do
    case $opts in
    f)
        performance_scripts_distribution=${OPTARG}
        ;;
    d)
        results_dir=${OPTARG}
        ;;
    k)
        key_file=${OPTARG}
        ;;
    n)
        key_name=${OPTARG}
        ;;
    j)
        jmeter_distribution=${OPTARG}
        ;;
    o)
        oracle_jdk_distribution=${OPTARG}
        ;;
    g)
        gcviewer_jar_path=${OPTARG}
        ;;
    s)
        stack_name_prefix=${OPTARG}
        ;;
    b)
        s3_bucket_name=${OPTARG}
        ;;
    r)
        s3_bucket_region=${OPTARG}
        ;;
    J)
        jmeter_client_ec2_instance_type=${OPTARG}
        ;;
    S)
        jmeter_server_ec2_instance_type=${OPTARG}
        ;;
    N)
        netty_ec2_instance_type=${OPTARG}
        ;;
    t)
        number_of_stacks=${OPTARG}
        ;;
    p)
        parallel_parameter_option=${OPTARG}
        ;;
    w)
        minimum_stack_creation_wait_time=${OPTARG}
        ;;
    h)
        usage
        exit 0
        ;;
    m)
        test_script=${OPTARG}
        ;;
    \?)
        usage
        exit 1
        ;;
    esac
done
shift "$((OPTIND - 1))"

run_performance_tests_options=("$@")

if [[ ! -f $performance_scripts_distribution ]]; then
    echo "Please provide Performance Distribution."
    exit 1
fi

performance_scripts_distribution_filename=$(basename $performance_scripts_distribution)

if [[ ${performance_scripts_distribution_filename: -7} != ".tar.gz" ]]; then
    echo "Performance Distribution must have .tar.gz extension"
    exit 1
fi

if [[ -z $results_dir ]]; then
    echo "Please provide a name to the results directory."
    exit 1
fi

if [[ -d $results_dir ]]; then
    echo "Results directory already exists. Please give a new name to the results directory."
    exit 1
fi

if [[ ! -f $key_file ]]; then
    echo "Please provide the key file."
    exit 1
fi

if [[ ${key_file: -4} != ".pem" ]]; then
    echo "AWS EC2 Key file must have .pem extension"
    exit 1
fi

if [[ -z $key_name ]]; then
    echo "Please provide the key name."
    exit 1
fi

key_filename=$(basename "$key_file")

if [[ "${key_filename%.*}" != "$key_name" ]]; then
    echo "WARNING: Key file does not match with the key name."
fi

if [[ ! -f $jmeter_distribution ]]; then
    echo "Please specify the JMeter distribution file (apache-jmeter-*.tgz)"
    exit 1
fi

jmeter_distribution_filename=$(basename $jmeter_distribution)

if [[ ${jmeter_distribution_filename: -4} != ".tgz" ]]; then
    echo "Please provide the JMeter tgz distribution file (apache-jmeter-*.tgz)"
    exit 1
fi

if [[ ! -f $oracle_jdk_distribution ]]; then
    echo "Please specify the Oracle JDK distribution file (jdk-8u*-linux-x64.tar.gz)"
    exit 1
fi

oracle_jdk_distribution_filename=$(basename $oracle_jdk_distribution)

if ! [[ $oracle_jdk_distribution_filename =~ ^jdk-8u[0-9]+-linux-x64.tar.gz$ ]]; then
    echo "Please specify a valid Oracle JDK distribution file (jdk-8u*-linux-x64.tar.gz)"
    exit 1
fi

if [[ ! -f $gcviewer_jar_path ]]; then
    echo "Please specify the path to GCViewer JAR file."
    exit 1
fi

if [[ -z $stack_name_prefix ]]; then
    echo "Please provide the stack name prefix."
    exit 1
fi

if [[ -z $s3_bucket_name ]]; then
    echo "Please provide S3 bucket name."
    exit 1
fi

if [[ -z $s3_bucket_region ]]; then
    echo "Please provide S3 bucket region."
    exit 1
fi

if [[ -z $jmeter_client_ec2_instance_type ]]; then
    echo "Please provide the Amazon EC2 Instance Type for JMeter Client."
    exit 1
fi

if [[ -z $jmeter_server_ec2_instance_type ]]; then
    echo "Please provide the Amazon EC2 Instance Type for JMeter Server."
    exit 1
fi

if [[ -z $netty_ec2_instance_type ]]; then
    echo "Please provide the Amazon EC2 Instance Type for Netty (Backend) Service."
    exit 1
fi

if ! [[ $minimum_stack_creation_wait_time =~ ^[0-9]+$ ]]; then
    echo "Please provide a valid minimum time to wait before polling for cloudformation stack's CREATE_COMPLETE status."
    exit 1
fi

if ! [[ $number_of_stacks =~ ^[0-9]+$ ]]; then
    echo "Please provide a valid number of stacks."
    exit 1
fi

if [[ -z $parallel_parameter_option ]]; then
    echo "Please provide the option character to parallelize tests."
    exit 1
fi

if ! [[ ${#parallel_parameter_option} -eq 1 ]]; then
    echo "Please provide a single option character to parallelize tests."
    exit 1
fi

if ! [[ $ALLOWED_OPTIONS == *"$parallel_parameter_option"* ]]; then
    echo "Invalid option. Allowed options to parallelize tests are $ALLOWED_OPTIONS."
    exit 1
fi

if function_exists validate; then
    validate
fi

if [[ -z $aws_cloudformation_template_filename ]]; then
    echo "Please set the AWS Cloudformation template file name from the script."
    exit 1
fi

if [[ -z $application_name ]]; then
    echo "Please set the application name from the script."
    exit 1
fi

if [[ -z $metrics_file_prefix ]]; then
    echo "Please set the prefix of application metrics files from the script."
    exit 1
fi

if ! function_exists get_columns; then
    echo "Please define a function named 'get_columns' in the script to get the columns to be included in markdown file."
    exit 1
fi

if [[ -z $test_script ]]; then
    test_script=run-performance-tests.sh
    exit 1
fi

test_script_filename=$(basename "$test_script")

if ! [[ ${test_script_filename: -3} != ".sh" ]]; then
    echo "Please specify the .sh test script."
    exit 1
fi

echo "Checking whether python requirements are installed..."
pip install -r $script_dir/python-requirements.txt

# Use absolute path
results_dir=$(realpath $results_dir)
mkdir $results_dir
echo "Results will be downloaded to $results_dir"
# Get absolute path of GCViewer
gcviewer_jar_path=$(realpath $gcviewer_jar_path)
# Copy scripts to results directory (in case if we need to use the scripts again)
cp $performance_scripts_distribution $results_dir

# Save metadata
declare -A test_parameters
test_parameters[jmeter_client_ec2_instance_type]="$jmeter_client_ec2_instance_type"
test_parameters[jmeter_server_ec2_instance_type]="$jmeter_server_ec2_instance_type"
test_parameters[netty_ec2_instance_type]="$netty_ec2_instance_type"

if function_exists get_test_metadata; then
    while IFS='=' read -r key value; do
        test_parameters[$key]="$value"
    done < <(get_test_metadata)
fi

test_parameters_json="."
test_parameters_args=""
for key in "${!test_parameters[@]}"; do
    test_parameters_json+=" | .[\"$key\"]=\$$key"
    test_parameters_args+=" --arg $key "${test_parameters[$key]}""
done
jq -n $test_parameters_args "$test_parameters_json" >$results_dir/cf-test-metadata.json

estimate_command="$script_dir/../jmeter/$test_script_filename -t ${run_performance_tests_options[@]}"
echo "Estimating total time for performance tests: $estimate_command"
# Estimating this script will also validate the options. It's important to validate options before creating the stack.
$estimate_command
# Save test metadata
mv test-metadata.json $results_dir

declare -a performance_test_options

if [[ $number_of_stacks -gt 1 ]]; then
    # Read options given to the performance test script. Refer jmeter/perf-test-common.sh
    declare -a options
    # Reset getopts
    OPTIND=0
    while getopts ":u:b:s:m:d:w:n:j:k:l:i:e:tp:h" opts ${run_performance_tests_options[@]}; do
        case $opts in
        $parallel_parameter_option)
            options+=("${OPTARG}")
            ;;
        *)
            run_performance_tests_remaining_options+=("-${opts}")
            [[ -n "$OPTARG" ]] && run_performance_tests_remaining_options+=("$OPTARG")
            ;;
        esac
    done
    minimum_params_per_stack=$(bc <<<"scale=0; ${#options[@]}/${number_of_stacks}")
    remaining_params=$(bc <<<"scale=0; ${#options[@]}%${number_of_stacks}")
    echo "Parallel option parameters: ${#options[@]}"
    echo "Number of stacks: ${number_of_stacks}"
    echo "Minimum parameters per stack: $minimum_params_per_stack"
    echo "Remaining parameters after distributing evenly: $remaining_params"

    option_counter=0
    remaining_option_counter=0
    for ((i = 0; i < $number_of_stacks; i++)); do
        declare -a options_per_stack=()
        for ((j = 0; j < $minimum_params_per_stack; j++)); do
            options_per_stack+=("${options[$option_counter]}")
            let option_counter=option_counter+1
        done
        if [[ $remaining_option_counter -lt $remaining_params ]]; then
            options_per_stack+=("${options[$option_counter]}")
            let option_counter=option_counter+1
            let remaining_option_counter=remaining_option_counter+1
        fi
        options_list=""
        for parameter_value in ${options_per_stack[@]}; do
            options_list+="-${parallel_parameter_option} ${parameter_value} "
        done
        performance_test_options+=("${options_list} ${run_performance_tests_remaining_options[*]}")
    done
else
    performance_test_options+=("${run_performance_tests_options[*]}")
fi

function read_concurrent_users() {
    declare -ag concurrent_users=()
    OPTIND=0
    while getopts ":u:" opts $@; do
        case $opts in
        u)
            concurrent_users+=("${OPTARG}")
            ;;
        esac
    done
}

declare -a jmeter_servers_per_stack

echo "Number of stacks to create: $number_of_stacks."
# echo "Performance test options given to stack(s): "
for ((i = 0; i < ${#performance_test_options[@]}; i++)); do
    declare -a options_array=(${performance_test_options[$i]})
    read_concurrent_users ${options_array[@]}
    # Determine JMeter Servers
    max_concurrent_users="0"
    for users in ${concurrent_users[@]}; do
        if [[ $users -gt $max_concurrent_users ]]; then
            max_concurrent_users=$users
        fi
    done
    jmeter_servers=1
    if [[ $max_concurrent_users -gt 500 ]]; then
        jmeter_servers=2
    fi
    jmeter_servers_per_stack+=("$jmeter_servers")
    performance_test_options[$i]+=" -n $jmeter_servers"
    estimate_command="$script_dir/../jmeter/$test_script_filename -t ${performance_test_options[$i]}"
    echo "$(($i + 1)): Estimating total time for the tests in stack $(($i + 1)) with $jmeter_servers JMeter server(s) handling a maximum of $max_concurrent_users concurrent users: $estimate_command"
    $estimate_command
done

temp_dir=$(mktemp -d)

# Get absolute paths
key_file=$(realpath $key_file)
performance_scripts_distribution=$(realpath $performance_scripts_distribution)
jmeter_distribution=$(realpath $jmeter_distribution)
oracle_jdk_distribution=$(realpath $oracle_jdk_distribution)

ln -s $key_file $temp_dir/$key_filename
ln -s $performance_scripts_distribution $temp_dir/$performance_scripts_distribution_filename
ln -s $jmeter_distribution $temp_dir/$jmeter_distribution_filename
ln -s $oracle_jdk_distribution $temp_dir/$oracle_jdk_distribution_filename

if function_exists create_links; then
    create_links
fi

echo "Syncing files in $temp_dir to S3 Bucket $s3_bucket_name..."
aws s3 sync --quiet --delete $temp_dir s3://$s3_bucket_name

echo "Listing files in S3 Bucket $s3_bucket_name..."
aws --region $s3_bucket_region s3 ls --summarize s3://$s3_bucket_name

declare -A cf_parameters
cf_parameters[KeyName]="$key_name"
cf_parameters[BucketName]="$s3_bucket_name"
cf_parameters[BucketRegion]="$s3_bucket_region"
cf_parameters[PerformanceDistributionName]="$performance_scripts_distribution_filename"
cf_parameters[JMeterDistributionName]="$jmeter_distribution_filename"
cf_parameters[OracleJDKDistributionName]="$oracle_jdk_distribution_filename"
cf_parameters[JMeterClientInstanceType]="$jmeter_client_ec2_instance_type"
cf_parameters[JMeterServerInstanceType]="$jmeter_server_ec2_instance_type"
cf_parameters[BackendInstanceType]="$netty_ec2_instance_type"

if function_exists get_cf_parameters; then
    while IFS='=' read -r key value; do
        cf_parameters[$key]="$value"
    done < <(get_cf_parameters)
fi

function delete_stack() {
    local stack_id="$1"
    local stack_delete_start_time=$(date +%s)
    echo "Deleting the stack: $stack_id"
    aws cloudformation delete-stack --stack-name $stack_id

    echo "Polling till the stack deletion completes..."
    aws cloudformation wait stack-delete-complete --stack-name $stack_id
    printf "Stack ($stack_id) deletion time: %s\n" "$(format_time $(measure_time $stack_delete_start_time))"
}

declare -a stack_ids

function exit_handler() {
    #Delete stack if it's already running
    for stack_id in ${stack_ids[@]}; do
        if aws cloudformation describe-stacks --stack-name $stack_id >/dev/null 2>&1; then
            delete_stack $stack_id
        fi
    done
    printf "Script execution time: %s\n" "$(format_time $(measure_time $script_start_time))"
}

trap exit_handler EXIT

# Create stacks
stack_create_start_time=$(date +%s)
for ((i = 0; i < ${#performance_test_options[@]}; i++)); do
    stack_name="${stack_name_prefix}$(($i + 1))"
    stack_results_dir="$results_dir/results-$(($i + 1))"
    mkdir -p $stack_results_dir
    cf_template=$stack_results_dir/${aws_cloudformation_template_filename}
    jmeter_servers=${jmeter_servers_per_stack[$i]}
    echo "JMeter Servers: $jmeter_servers"
    $script_dir/create-template.py --template-name ${aws_cloudformation_template_filename} --output-name $cf_template \
        --jmeter-servers $jmeter_servers --start-bastian
    echo "Validating stack: $stack_name: $cf_template"
    aws cloudformation validate-template --template-body file://$cf_template
    if [[ $jmeter_servers -eq 1 ]]; then
        cf_parameters[JMeterClientInstanceType]="$jmeter_server_ec2_instance_type"
    fi

    cf_parameters_str=""
    for key in "${!cf_parameters[@]}"; do
        cf_parameters_str+=" ParameterKey=${key},ParameterValue=${cf_parameters[$key]}"
    done
    create_stack_command="aws cloudformation create-stack --stack-name $stack_name \
        --template-body file://$cf_template --parameters $cf_parameters_str \
        --capabilities CAPABILITY_IAM"

    echo "Creating stack $stack_name..."
    echo "$create_stack_command"
    # Create stack
    stack_id="$($create_stack_command)"
    # stack_id="Stack"
    stack_ids+=("$stack_id")
    echo "Created stack: $stack_name. ID: $stack_id"
done

function save_logs_and_delete_stack() {
    local stack_id="$1"
    local stack_name="$2"
    local stack_results_dir="$3"
    # Get stack events
    local stack_events_json=$stack_results_dir/stack-events.json
    echo "Saving $stack_name stack events to $stack_events_json"
    aws cloudformation describe-stack-events --stack-name $stack_id --no-paginate --output json >$stack_events_json
    # Check whether there are any failed events
    cat $stack_events_json | jq '.StackEvents | .[] | select ( .ResourceStatus == "CREATE_FAILED" )'

    # Download log events
    log_group_name="${stack_name}-CloudFormationLogs"
    local log_streams_json=$stack_results_dir/log-streams.json
    if aws logs describe-log-streams --log-group-name $log_group_name --output json >$log_streams_json; then
        local log_events_file=$stack_results_dir/log-events.log
        for log_stream in $(cat $log_streams_json | jq -r '.logStreams | .[] | .logStreamName'); do
            echo "[$log_group_name] Downloading log events from stream: $log_stream..."
            echo "#### The beginning of log events from $log_stream" >>$log_events_file
            aws logs get-log-events --log-group-name $log_group_name --log-stream-name $log_stream --output text >>$log_events_file
            echo -ne "\n\n#### The end of log events from $log_stream\n\n" >>$log_events_file
        done
    fi

    delete_stack $stack_id
}

function run_perf_tests_in_stack() {
    local index=$1
    local stack_id=$2
    local stack_name=$3
    local stack_results_dir=$4
    trap "save_logs_and_delete_stack ${stack_id} ${stack_name} ${stack_results_dir}" EXIT
    trap "save_logs_and_delete_stack ${stack_id} ${stack_name} ${stack_results_dir}" RETURN
    printf "Running performance tests on '%s' stack.\n" "$stack_name"

    # Sleep for sometime before waiting
    # This is required since the 'aws cloudformation wait stack-create-complete' will exit with a
    # return code of 255 after 120 failed checks. The command polls every 30 seconds, which means that the
    # maximum wait time is one hour.
    # Due to the dependencies in CloudFormation template, the stack creation may take more than one hour.
    echo "Waiting ${minimum_stack_creation_wait_time}m before polling for CREATE_COMPLETE status of the stack: $stack_name"
    sleep ${minimum_stack_creation_wait_time}m
    # Wait till completion
    echo "Polling till the stack creation completes..."
    aws cloudformation wait stack-create-complete --stack-name $stack_id
    printf "Stack creation time: %s\n" "$(format_time $(measure_time $stack_create_start_time))"

    echo "Getting JMeter Client Public IP..."
    jmeter_client_ip="$(aws cloudformation describe-stacks --stack-name $stack_id --query 'Stacks[0].Outputs[?OutputKey==`JMeterClientPublicIP`].OutputValue' --output text)"
    echo "JMeter Client Public IP: $jmeter_client_ip"

    run_performance_tests_command="./jmeter/$test_script_filename ${performance_test_options[$index]}"
    # Run performance tests
    run_remote_tests="ssh -i $key_file -o "StrictHostKeyChecking=no" -T ubuntu@$jmeter_client_ip $run_performance_tests_command"
    echo "Running performance tests: $run_remote_tests"
    # Handle any error and let the script continue.
    $run_remote_tests || echo "Remote test ssh command failed: $run_remote_tests"

    echo "Downloading results-without-jtls.zip"
    # Download results-without-jtls.zip
    scp -i $key_file -o "StrictHostKeyChecking=no" ubuntu@$jmeter_client_ip:results-without-jtls.zip $stack_results_dir
    echo "Downloading results.zip"
    # Download results.zip
    scp -i $key_file -o "StrictHostKeyChecking=no" ubuntu@$jmeter_client_ip:results.zip $stack_results_dir

    if [[ ! -f $stack_results_dir/results-without-jtls.zip ]]; then
        echo "Failed to download the results-without-jtls.zip"
        exit 500
    fi

    if [[ ! -f $stack_results_dir/results.zip ]]; then
        echo "Failed to download the results.zip"
        exit 500
    fi
}

for ((i = 0; i < ${#stack_ids[@]}; i++)); do
    stack_id=${stack_ids[$i]}
    stack_name="${stack_name_prefix}$(($i + 1))"
    stack_results_dir="$results_dir/results-$(($i + 1))"
    log_file="${stack_results_dir}/run.log"
    run_perf_tests_in_stack $i ${stack_id} ${stack_name} ${stack_results_dir} 2>&1 | ts "[${stack_name}] [%Y-%m-%d %H:%M:%S]" | tee ${log_file} &
done

# See current jobs
echo "Jobs: "
jobs
echo "Waiting till all performance test jobs are completed..."
# Wait till parallel tests complete
wait

echo "Creating summary.csv..."
# Extract all results.
for ((i = 0; i < ${#performance_test_options[@]}; i++)); do
    stack_results_dir="$results_dir/results-$(($i + 1))"
    unzip -nq ${stack_results_dir}/results-without-jtls.zip -x '*/test-metadata.json' -d $results_dir
done
cd $results_dir
# Create CSV
$script_dir/../jmeter/create-summary-csv.sh -d results -n "${application_name}" -p "${metrics_file_prefix}" -j 2 -g "${gcviewer_jar_path}"
# Copy metadata
cp cf-test-metadata.json test-metadata.json results
# Zip results
zip -9qmr results-all.zip results/

# Use following to get all column names:
echo "Available column names:"
while read -r line; do echo "\"$line\""; done < <($script_dir/../jmeter/create-summary-csv.sh -n "${application_name}" -j 2 -i -x)
echo -ne "\n\n"

declare -a column_names

while read column_name; do
    column_names+=("$column_name")
done < <(get_columns)

echo "Creating summary results markdown file..."
$script_dir/../jmeter/create-summary-markdown.py --json-files cf-test-metadata.json test-metadata.json --column-names "${column_names[@]}"

echo "Results:"
cat summary.csv | cut -d, -f 1-11 | column -t -s,
