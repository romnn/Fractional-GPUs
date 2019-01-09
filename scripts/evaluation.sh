#!/bin/bash

# Run this script without any arguments. It takes arguments from user during
# runtime.

COMMON_SCRIPT=../scripts/common.sh

if [ ! -f $COMMON_SCRIPT ]; then
    echo "Run this script from \$PROJ_DIR/scripts folder"
fi

source $COMMON_SCRIPT

# Different modes of FGPU
FGPU_DISABLED=1                  # No compute/memory partitioning
FGPU_COMPUTE_ONLY=2              # Compute partitioning only
FGPU_COMPUTE_AND_MEMORY=3        # Compute and memory partitioning
FGPU_VOLTA_COMPUTE_ONLY=4        # For only volta GPU, we have Volta MPS based compute partitoning
FGPU_REVERSE_ENGINEERING=5       # Reverse engineering

# Tracks the current FGPU mode
FGPU_MODE=''
FGPU_MODE_NAME=''

# Different modes of evaluation
EVAL_REVERSE=1                   # Reverse engineering
EVAL_BENCHMARK=2                 # Benchmark using CUDA/Rodinia
EVAL_CAFFE=3                     # Benchmark using caffe

# Tracks the current evaluation mode
EVAL_MODE=''

# Step 1 - Find the GPU
check_is_volta_gpu
IS_VOLTA=$?

# Prints out current FGPU mode
print_fgpu_mode() {
    echo    "*****************************************"
    echo    "Running in FGPU MODE: $FGPU_MODE_NAME"
    echo    "*****************************************"
    
    return 0
}

# Configures FGPU in a specific mode
# First argument is the FGPU mode number
configure_fgpu() {
    # If FGPU is already set to the desired mode, skip configuring
    if [ "$FGPU_MODE" == "$1" ]; then
        return 0
    fi

    case $1 in
    1)
        echo "*********************************"
        echo "Configuring FGPU in disabled mode"
        echo "*********************************"
        FGPU_MODE=$FGPU_DISABLED
        FGPU_MODE_NAME="FGPU DISABLED"
        build_and_install_fgpu "FGPU_COMP_COLORING_ENABLE=OFF" "FGPU_MEM_COLORING_ENABLED=OFF" "FGPU_TEST_MEM_COLORING_ENABLED=OFF"
        ;;

    2)
        echo "**************************************************"
        echo "Configuring FGPU in compute partitioning only mode"
        echo "**************************************************"
        FGPU_MODE=$FGPU_COMPUTE_ONLY
        FGPU_MODE_NAME="FGPU COMPUTE ONLY PARTITIONING MODE"
        build_and_install_fgpu "FGPU_COMP_COLORING_ENABLE=ON" "FGPU_MEM_COLORING_ENABLED=OFF" "FGPU_TEST_MEM_COLORING_ENABLED=OFF"
        ;;
    3)
        echo "********************************************************"
        echo "Configuring FGPU in compute and memory partitioning mode"
        echo "********************************************************"
        FGPU_MODE=$FGPU_COMPUTE_AND_MEMORY 
        FGPU_MODE_NAME="FGPU COMPUTE AND MEMORY PARTITIONING MODE"
        build_and_install_fgpu "FGPU_COMP_COLORING_ENABLE=ON" "FGPU_MEM_COLORING_ENABLED=ON" "FGPU_TEST_MEM_COLORING_ENABLED=OFF"
        ;;
    4)
        echo "********************************************"
        echo "Configuring FGPU in reverse engineering mode"
        echo "********************************************"
        FGPU_MODE=$FGPU_REVERSE_ENGINEERING 
        FGPU_MODE_NAME="FGPU VOLTA COMPUTE ONLY PARTITIONING MODE"
        build_and_install_fgpu "FGPU_COMP_COLORING_ENABLE=ON" "FGPU_MEM_COLORING_ENABLED=ON" "FGPU_TEST_MEM_COLORING_ENABLED=ON"
        ;;
    5)
        echo "************************************************************************************************"
        echo "Configuring FGPU in disabled mode (Volta MPS will do the compute partitioning, FGPU is bypassed)"
        echo "************************************************************************************************"
        FGPU_MODE=$FGPU_VOLTA_COMPUTE_ONLY
        FGPU_MODE_NAME="FGPU REVERSE ENGINEERING MODE"
        build_and_install_fgpu "FGPU_COMP_COLORING_ENABLE=OFF" "FGPU_MEM_COLORING_ENABLED=OFF" "FGPU_TEST_MEM_COLORING_ENABLED=OFF"
        ;;
    esac

    return 0
}

# Ask user's input and correspondingly configure FGPU
ask_and_configure_fgpu() {
    echo "Choose one of the following FGPU modes of configuration (available for current GPU)"
    echo "1) Computational Partitioning Only"
    echo "2) Computational and Memory Partitioning"
    if [ $IS_VOLTA -ne 0 ]; then
        echo "3) Volta MPS based Compute partitioning (FGPU bypassed)"
        echo "Enter option(1 or 2 or 3): "
    else
        echo "Enter option(1 or 2): "
    fi
    
    read fgpu_mode_number
    echo ""

    if [ $IS_VOLTA -ne 0 ]; then
        check_arg_between $fgpu_mode_number 1 3
    else
        check_arg_between $fgpu_mode_number 1 2
    fi

    # We do not allow user to disable fgpu so we skipped that option
    # Internal scripts function can disable fgpu
    fgpu_mode_number=$((fgpu_mode_number+1))

    if [ $? -ne 0 ]; then
        do_error_exit "Invalid option"
    fi

    configure_fgpu $fgpu_mode_number

    return 0
}

# If can of error, cleanup
function do_for_sigint() {
    kill_process $REVERSE_ENGINEERING_BINARY
    deinit_fgpu
    exit 1
}

trap 'do_for_sigint' EXIT

# Runs a benchmark with an interference
# Arg 1 is the command to launch the benchmark
# Sets the variable BENCHMARK_RUNTIME to the average runtime
unset BENCHMARK_RUNTIME
run_benchmark() {

    cur_dir=`pwd`

    cd $BENCHMARK_PATH

    # Print to stdout and store in variable
    echo ""
    output=$(sudo $1 | tee /dev/tty)
    echo ""

    if [ $? -ne 0 ]; then
        do_error_exit "Couldn't run benchmark"
    fi

    # Get the runtime
    BENCHMARK_RUNTIME=`echo $output | grep -oP '(?<=AVG_RUNTIME: )[0-9.]+'`
    if [ $? -ne 0 ]; then
        do_error_exit "Couldn't find the runtime of benchmark"
    fi

    cd $cur_dir
}

# Using GNU plot, plots and save benchmark results
# First argument is the input data file
# Second argument is the output png file
# Third argument is the FGPU mode
# Fourth is number of colors
# Fifth is number of iterations
# Sixth is number of benchmark applications
# Seventh is number of interference
plot_benchmark() {
    
    # Check if gnuplot exists?
    check_if_installed "gnuplot"

    gnu_command=""

    # Create color pallete
    # Varying shaded of red
    num_it=$7
    num_b=$6
    index=0
    for i in $(seq 1 $num_b); 
    do
        shade="0xFF"
        for j in $(seq 1 $num_it)
        do
            index=$((index+1))
            color_shade=`printf "%.2X\n" $((shade - 0XFF/2/num_it))`
            shade="0x$color_shade"
            color="#FF$color_shade$color_shade"
            gnu_command="$gnu_command;set linetype $index lc rgb  '$color'"
        done
    done

    gnu_command="$gnu_command;
        set term 'pngcairo' size 1280,960;
        set output '$2';
        set title 'Normalized Average Runtime of Benchmarks ($3, Number of Colors:$4, Number of Iterations:$5)';
        set ylabel 'Normalized Runtime';
        set xlabel 'Benchmark-Interference';
        set key autotitle columnhead;
        set boxwidth 0.5;
        set style fill solid;
        set grid;
        set xtics rotate;
        set key noenhanced;
        set xtics noenhanced;
        plot '$1' using 1:6:1:xticlabels(stringcolumn(2)) with boxes lc var, '' using 1:6:6 with labels offset char 0,1;
    "

    gnuplot -e "$gnu_command"

    if [ $? -ne 0 ]; then
        do_error_exit "Failed to plot histogram"
    fi

    return 0

}

# Step 2 - Chose the evaluation
echo "Choose one of the following evaluation modes"
echo "1) Reverse engineering of GPU (Get hidden details about the GPU)"
echo "2) Show results of benchmarks (CUDA/Rodinia applications)"
echo "3) Show results of benchmarks (Caffe application)"
echo "Enter option(1 or 2 or 3): " 
read evaluation_mode_number
echo ""

check_arg_between $evaluation_mode_number 1 3

case $evaluation_mode_number in
    1)
        EVAL_MODE=$EVAL_REVERSE
        configure_fgpu $FGPU_REVERSE_ENGINEERING
        
        init_fgpu

        echo "********************************"
        echo "Running reverse engineering code"
        echo "********************************"

        # Start the reverse engineering code
        # Print the histogram and treadline of DRAM bank access time
        # Histogram - 10K samples and bin size of 5 clock cycles
        # Also show the results of inteference on cachelines and DRAM banks
        hist_file=`mktemp`
        treadline_file=`mktemp`
        inteference_file=`mktemp`
        hist_outfile=`mktemp`
        treadline_outfile=`mktemp`
        inteference_outfile=`mktemp`
        hist_outfile="$hist_outfile.png"
        treadline_outfile="$treadline_outfile.png"
        inteference_outfile="$inteference_outfile.png"

        $BIN_PATH/$REVERSE_ENGINEERING_BINARY -n 10000 -s 5 -H $hist_file -T $treadline_file -I $inteference_file
        if [ $? -ne 0 ]; then
            do_error_exit "Reverse engineering code failed"
        fi

        echo "*********************************************************************************"
        echo "Showing Treadline of DRAM Bank access time (Saving plot to $treadline_outfile)"
        echo "*********************************************************************************"
        $REVERSE_ENGINEERING_PATH/$REVERSE_ENGINEERING_PLOT -T=$treadline_file -t=$treadline_outfile
        if [ $? -ne 0 ]; then
            do_error_exit "Failed to plot trendline"
        fi
        pause_for_user_input

        echo "******************************************************************************"
        echo "Showing Histogram of DRAM Bank access time  (Saving plot to $hist_outfile)"
        echo "******************************************************************************"
        $REVERSE_ENGINEERING_PATH/$REVERSE_ENGINEERING_PLOT -G=$hist_file -g=$hist_outfile
        if [ $? -ne 0 ]; then
            do_error_exit "Failed to plot histogram"
        fi
        pause_for_user_input

        echo "**************************************************************************************"
        echo "Showing results of interference expermients (Saving plot to $inteference_outfile)"
        echo "**************************************************************************************"
        $REVERSE_ENGINEERING_PATH/$REVERSE_ENGINEERING_PLOT -I=$inteference_file -i=$inteference_outfile
        if [ $? -ne 0 ]; then
            do_error_exit "Failed to plot inteference expermients result"
        fi
        pause_for_user_input

        deinit_fgpu
        ;;

    2)
        EVAL_MODE=$EVAL_BENCHMARK

        echo "INFO: Benchmarks can run in different modes. The runtimes of benchmarks are normalized wrt to FGPU disabled mode."
        ask_and_configure_fgpu
        chosen_fgpu_mode=$FGPU_MODE_NAME

        num_iterations=1000
        echo "Enter the number of iterations of each benchmark. Average results are reported (Default $num_iterations):"
        read num_iterations
        echo ""

        if [ -z $num_iterations ]; then
            num_iterations=1000
        else
            check_arg_is_number $num_iterations
        fi

        num_colors=2

        if [ $IS_VOLTA -ne 0 ]; then
            echo "Enter the number of total partitions. Default is $num_colors (Valid options are 2,4,8):"
            read num_colors
            echo ""
            check_arg_is_number $num_colors

            if [ $num_colors -ne 2 ] && [ $num_colors -ne 4 ] && [ $num_colors -ne 8 ]; then
                do_error_exit "Invalid argument"
            fi

        else
            echo "GPU only supports 2 partitions. Using this value."
        fi

        cur_dir=`pwd`
        cd $BENCHMARK_PATH
        # Get list of benchmark applications
        list_benchmark=`$BENCHMARK_PATH/$BENCHMARK_SCRIPT -B`
        # Get list of inteference applications
        list_interference=`$BENCHMARK_PATH/$BENCHMARK_SCRIPT -I`
        cd $cur_dir

        # Print out
        echo ""
        echo "$list_benchmark"
        echo ""
        echo "$list_interference"
        echo ""

        declare -a benchmarks
        declare -a inteferences

        while read b; do
            benchmarks+=("$b")
        done < <(echo "$list_benchmark" | tail -n +2) # Omit the first line which is a explaining statement

        while read i; do
            inteferences+=("$i")
        done < <(echo "$list_interference" | tail -n +2)

        print_fgpu_mode

        declare -a runtimes
        declare -a baseline
        declare -a normalized

        for b in "${benchmarks[@]}"
        do
            for i in "${inteferences[@]}"
            do
                echo "*************************************************"
                echo "Running Benchmark:$b with Interference:$i"
                echo "*************************************************"

                cmd="$BENCHMARK_PATH/$BENCHMARK_SCRIPT -c=$num_colors -n=$num_iterations -i=$i -b=$b"
                run_benchmark "$cmd"
                runtimes+=($BENCHMARK_RUNTIME)
            done
        done

        echo "INFO: Running with FGPU disabled (no partitioning) mode to gather baseline runtimes (to normalize)"
        echo "INFO: For measuring baseline, we disable FGPU and for each benchmark, we run it alone without any interference"
        configure_fgpu $FGPU_DISABLED
        print_fgpu_mode
        
        for b in "${benchmarks[@]}"
        do
            # For normalization, base case is when FGPU is disabled,
            # and benchmark application runs alone fully utilizing the whole
            # GPU
            i="__none__"
            echo "*************************************************"
            echo "Running Benchmark:$b with Interference:$i"
            echo "*************************************************"

            cmd="$BENCHMARK_PATH/$BENCHMARK_SCRIPT -c=$num_colors -n=$num_iterations -i=$i -b=$b"
            run_benchmark "$cmd"
            base=($BENCHMARK_RUNTIME)

            for i in "${inteferences[@]}"
            do
                baseline+=($base)
            done
        done

        for i in "${!runtimes[@]}"; 
        do
            run=${runtimes[i]}
            base=${baseline[i]}
            norm=`bc -l <<< $run/$base/$num_colors`
            normalized+=("$norm")

            # Trim
            runtimes[i]=`printf "%.2f" $run`
            baseline[i]=`printf "%.2f" $base`
            normalized[i]=`printf "%.2f" $norm`
        done

        result_file=`mktemp`
        printf "Index\tBenchmark-Interference\tNumIterations\tNumColors\tAvgRunTime\tNormalizedRunTime\n" > $result_file

        index=0
        for b in "${benchmarks[@]}"
        do
            for i in "${inteferences[@]}"
            do
                run=${runtimes[index]}
                norm=${normalized[index]}
                index=$((index+1))
                printf "$index\t$b-$i\t$num_iterations\t$num_colors\t$run\t$norm\n" >> $result_file
            done
        done

        echo ""
        echo "Printing Results for $chosen_fgpu_mode"

        cat $result_file

        echo ""
        echo "****************************************************"
        echo "Raw benchmark results saved in file $result_file"
        echo "****************************************************"
        
        output_plot=`mktemp`
        output_plot="$output_plot.png"
        plot_benchmark "$result_file" "$output_plot" "$chosen_fgpu_mode" $num_colors $num_iterations "${#benchmarks[*]}" "${#inteferences[*]}"

        echo ""
        echo "****************************************************"
        echo "Benchmark results plot is saved in file $output_plot"
        echo "****************************************************"
        pause_for_user_input

        ;;
    3)
        FGPU_MODE=$EVAL_CAFFE
        echo "TODO: To be implemented in the script"
        ;;
esac

echo "Reached end. Restart script to explore more options."