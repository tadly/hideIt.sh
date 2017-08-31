#!/usr/bin/env bash
#
#   Automagically hide/show a window by its name when the cursor is
#   within a defined region or you mouse over it.
#
#   This script was initially written to imitate gnome-shell's systray
#   but should be generic enough to do other things as well.
#
#   Requirements:
#      bash, xdotool, xwininfo, xev
#

# Global variables used throughout the script
win_id=""
win_name=""
win_class=""
win_instance=""

win_width=""
win_height=""
win_posX=""
win_posY=""

screen_width=""
screen_height=""

minX=""
minY=""
maxX=""
maxY=""

hover=1
signal=1
interval=1
peek=3
direction="left"
steps=3
no_trans=1
toggle=1

_is_hidden=1
_has_region=1
_pid_file=""


usage() {
    # Print usage
    printf "usage: $0 [options]\n"
    printf "\n"
    printf "Required (At least on):\n"
    printf " -N, --name [pattern]\n"
    printf "   Match against the window name.\n"
    printf "   This is the same string that is displayed in the window titlebar.\n"
    printf "\n"
    printf " -C, --class [pattern]\n"
    printf "   Match against the window class.\n"
    printf "\n"
    printf " -I, --instance [pattern]\n"
    printf "   Match against the window instance.\n"
    printf "\n"
    printf " --id [window-id]\n"
    printf "   Explicitly specify a window id rather than searching for one.\n"
    printf "\n"
    printf "Optional:\n"
    printf " -r, --region [posXxposY+offsetX+offsetY]\n"
    printf "   Cursor region at which to trigger.\n"
    printf "   Examples:\n"
    printf "     --region 0x1080+10+-10 (Bottom left incl. a 10 pixel offset)\n"
    printf "     --region 1920x1080+0+0 (Bottom right without offset)\n"
    printf "\n"
    printf " -H, --hover\n"
    printf "   Show the window when hovering over it.\n"
    printf "   If --region was defined, --hover will be ignored!\n"
    printf "   This will only work if --peek is greater 0.\n"
    printf "   By default, hover is off.\n"
    printf "\n"
    printf " -S, --signal\n"
    printf "   Toggle the visibility by sending a 'SIGUSR1' signal.\n"
    printf "   Both --region and --hover will be ignored.\n"
    printf "\n"
    printf " -i, --interval [interval]\n"
    printf "   Interval in seconds to check the cursors location.\n"
    printf "   Defaults to 1.\n"
    printf "\n"
    printf " -p, --peek [amount]\n"
    printf "   When hidden, peek 'amount' of pixels to indicate the window.\n"
    printf "   Required if --hover is used."
    printf "   Defaults to 3.\n"
    printf "\n"
    printf " -d, --direction [left|right|top|bottom]\n"
    printf "   Direction in which to move the window.\n"
    printf "   Defaults to left.\n"
    printf "\n"
    printf " -s, --steps [amount]\n"
    printf "   Steps in pixel used to move the window. The higher the value,\n"
    printf "   the faster it will move at the cost of smoothness.\n"
    printf "   Defaults to 3.\n"
    printf "\n"
    printf " -T, --no-trans\n"
    printf "   Turn of the transition effect.\n"
    printf "\n"
    printf " -t, --toggle\n"
    printf "   Try to send a SIGUSR1 to the process running with the SAME NAME.\n"
    printf "   If the process can not be uniquely identified, do nothing.\n"
    printf "\n\n"
    printf "Examples:\n"
    printf "  Dropdown Terminal:\n"
    printf "    # Start a terminal with a unique name\n"
    printf "    # (Make sure yourself it is positioned correctly)\n"
    printf "    $ termite --title=dropdown-terminal &\n"
    printf "\n"
    printf "    # Hide it and wait for a SIGUSR1 signal\n"
    printf "    $ hideIt.sh --name '^dropdown-terminal$' --direction top --steps 5 --signal\n"
    printf "\n"
    printf "    # Send a SIGUSR1 signal (This could be mapped to a keyboard shortcut)\n"
    printf "    $ hideIt.sh --name '^dropdown-terminal$' --toggle\n"
}


argparse() {
    # Parse system args
    while [ $# -gt 0 ]; do
        case $1 in
            "-N"|"--name")
                win_name="$2"
                shift
                ;;
            "-C"|"--class")
                win_class="$2"
                shift
                ;;
            "-I"|"--instance")
                win_instance="$2"
                shift
                ;;
            "--id")
                if [[ ! $2 =~ [0-9]+ ]]; then
                    printf "Invalid window id. Should be a number.\n" 1>&2
                    exit 1
                fi

                win_id="$2"
                shift
                ;;
            "-H"|"--hover")
                hover=0
                ;;
            "-S"|"--signal")
                signal=0
                ;;
            "-r"|"--region")
                local posX posY offsetX offsetY
                read posX posY offsetX offsetY <<<$(echo "$2" | \
                    sed -rn 's/^([0-9]+)x([0-9]+)\+(-?[0-9]+)\+(-?[0-9]+)/\1 \2 \3 \4/p')

                # Test if we have proper values by trying
                # to add them all together
                expr $posX + $posY + $offsetX + $offsetY > /dev/null 2>&1
                if [ $? -ne 0 ]; then
                    printf "Invalid region. See --help for usage.\n" 1>&2
                    exit 1
                fi

                minX=$posX
                maxX=$((${minX} + ${offsetX}))
                if [ $minX -gt $maxX ]; then
                    read minX maxX <<< "$maxX $minX"
                fi

                minY=$posY
                maxY=$((${minY} + ${offsetY}))
                if [ $minY -gt $maxY ]; then
                    read minY maxY <<< "$maxY $minY"
                fi

                if [[ ! $minX =~ [0-9]+ ]] || [[ ! $minY =~ [0-9]+ ]] \
                        || [[ ! $maxY =~ [0-9]+ ]] || [[ ! $maxY =~ [0-9]+ ]]; then
                    printf "Missing or invalid region. See --help for usage.\n" 1>&2
                    exit 1
                fi
                _has_region=0
                shift
                ;;
            "-i"|"--interval")
                interval="$2"
                if [[ ! $interval =~ [0-9]+ ]]; then
                    printf "Interval should be a number. " 1>&2
                    exit 1
                fi
                shift
                ;;
            "-p"|"--peek")
                peek="$2"
                if [[ ! $peek =~ [0-9]+ ]]; then
                    printf "Peek should be a number. " 1>&2
                    exit 1
                fi
                shift
                ;;
            "-d"|"--direction")
                direction="$2"
                if [[ ! "$direction" =~ ^(left|right|top|bottom)$ ]]; then
                    printf "Invalid direction. See --help for usage.\n" 1>&2
                    exit 1
                fi
                shift
                ;;
            "-s"|"--steps")
                steps="$2"
                if [[ ! $steps =~ [0-9]+ ]]; then
                    printf "Steps should be a number. " 1>&2
                    exit 1
                fi
                shift
                ;;
            "-T"|"--no-trans")
                no_trans=0
                ;;
            "-t"|"--toggle")
                toggle=0
                ;;
            "-h"|"--help")
                usage
                exit 0
                ;;
            **)
                printf "Didn't understand '$1'\n" 1>&2
                printf "See --help for usage.\n"
                exit 1
                ;;
        esac
        shift
    done

    # Check required arguments
    local _names="$win_name$win_class$$win_instance"
    if [ -z "$_names" ] && [ -z "$win_id" ]; then
        printf "At least one of --name, --class, --instance or --id" 1>&2
        printf " is required!\n" 1>&2
        exit 1
    fi

    if [ $toggle -ne 0 ] && [ $signal -ne 0 ] && [ $_has_region -ne 0 ] \
            && [ $hover -ne 0 ]; then
        printf "At least one of --toggle, --signal, --hover or" 1>&2
        printf " --region is required!\n" 1>&2
        exit 1
    fi
}


function fetch_window_id() {
    # Sets the values for the following global
    #   win_id

    # We already have a window id
    if [ ! -z "$win_id" ]; then
        _pid_file="/tmp/hideIt-${win_id}.pid"
        return
    fi

    local _id=-1

    # Search all windows matching the provided class
    local _tmp1=()
    if [ ! -z "$win_class" ]; then
        _tmp1=($(xdotool search --class "$win_class"))
        _tmp1=${_tmp1:--1}
    fi

    # Search all windows matching the provided instance
    local _tmp2=()
    if [ ! -z "$win_instance" ]; then
        _tmp2=($(xdotool search --classname "$win_instance"))
        _tmp2=${_tmp2:--1}
    fi

    # Search all windows matching the provided name (title)
    local _tmp3=()
    if [ ! -z "$win_name" ]; then
        _tmp3=($(xdotool search --name "$win_name"))
        _tmp3=${_tmp3:--1}
    fi

    # Shift values upwards
    for i in {1..2}; do
        if [ -z $_tmp1 ]; then
            _tmp1=(${_tmp2[@]})
            _tmp2=()
        fi

        if [ -z $_tmp2 ]; then
            _tmp2=(${_tmp3[@]})
            _tmp3=()
        fi
    done

    if [ -z $_tmp2 ]; then
        # We only have one list of ids so we pick the first one from it
        _id=${_tmp1[0]}
    else
        # We have multiple lists so we have to find the id that appears
        # in all of them
        local _oldIFS=$IFS
        IFS=$'\n\t'

        local _ids=($(comm -12 \
            <(echo "${_tmp1[*]}" | sort) \
            <(echo "${_tmp2[*]}" | sort)))

        if [ ! -z $_tmp3 ]; then
            _ids=($(comm -12 \
                <(echo "${_tmp3[*]}" | sort) \
                <(echo "${_ids[*]}" | sort)))
        fi
        IFS=$_oldIFS

        _id=${_ids[0]}
    fi

    if [[ $_id =~ [0-9]+ ]] && [ $_id -gt 0 ]; then
        win_id=$_id
        _pid_file="/tmp/hideIt-${win_id}.pid"
    fi
}


function fetch_screen_dimensions() {
    # Sets the values for the following globals
    #    screen_width, screen_height

    local win_info=$(xwininfo -root)
    screen_width=$(echo "$win_info" | sed -rn 's/.*Width: +([0-9]+)/\1/p')
    screen_height=$(echo "$win_info" | sed -rn 's/.*Height: +([0-9]+)/\1/p')
}


function fetch_window_dimensions() {
    # Sets the values for the following globals unless no win_id exists
    #    win_width, win_height, win_posX, win_posY
    if [[ ! $win_id =~ [0-9]+ ]]; then
        return
    fi

    local win_info=$(xwininfo -id $win_id)

    win_width=$(echo "$win_info" | sed -rn 's/.*Width: +([0-9]+)/\1/p')
    win_height=$(echo "$win_info" | sed -rn 's/.*Height: +([0-9]+)/\1/p')

    if [ ! -z "$1" ] && [ $1 -eq 0 ]; then
        win_posX=$(echo "$win_info" | \
            sed -rn 's/.*Absolute upper-left X: +(-?[0-9]+)/\1/p')
        win_posY=$(echo "$win_info" | \
            sed -rn 's/.*Absolute upper-left Y: +(-?[0-9]+)/\1/p')
    fi
}


function toggle_instance() {
    if [ ! -f "$_pid_file" ]; then
        printf "Pid file at \"${_pid_file}\" doesn't exist!\n" 1>&2
        exit 1
    fi

    local _pid=`cat $_pid_file`
    printf "Toggeling instance...\n"

    if [[ $_pid =~ [0-9]+ ]]; then
        kill -SIGUSR1 $_pid
        exit 0
    else
        printf "Invalid pid in \"${_pid_file}\".\n" 1>&2
        exit 1
    fi
}


function hide_window() {
    # Move the window in or out
    # Args:
    #     hide: 0 to hide, 1 to show
    local hide=$1

    _is_hidden=$hide

    # Update win_width, win_height in case they changed
    fetch_window_dimensions

    # Activate the window.
    # Should bring it to the front, change workspace etc.
    if [ $hide -ne 0 ]; then
        xdotool windowactivate $win_id > /dev/null 2>&1
    fi

    # Generate the sequence used to move the window
    local to=()
    local sequence=()
    if [ "$direction" == "left" ]; then
        to=-$(($win_width - $peek))
        if [ $hide -eq 0 ]; then
            sequence=($(seq $win_posX -$steps $to))
            sequence+=($to)
        else
            sequence=($(seq $to $steps $win_posX))
            sequence+=($win_posX)
        fi

    elif [ "$direction" == "right" ]; then
        to=$(($screen_width - $peek))
        if [ $hide -eq 0 ]; then
            sequence=($(seq $win_posX $steps $to))
            sequence+=($to)
        else
            sequence=($(seq $to -$steps $win_posX))
            sequence+=($win_posX)
        fi

    elif [ "$direction" == "bottom" ]; then
        to=$(($screen_height - $peek))
        if [ $hide -eq 0 ]; then
            sequence=($(seq $win_posY $steps $to))
            sequence+=($to)
        else
            sequence=($(seq $to -$steps $win_posY))
            sequence+=($win_posY)
        fi

    elif [ "$direction" == "top" ]; then
        to=-$(($win_height - $peek))
        if [ $hide -eq 0 ]; then
            sequence=($(seq $win_posY -$steps $to))
            sequence+=($to)
        else
            sequence=($(seq $to $steps $win_posY))
            sequence+=($win_posY)
        fi
    fi

    # Actually move the window
    if [ $no_trans -ne 0 ]; then
        for pos in ${sequence[@]}; do
            if [[ "$direction" =~ ^(left|right)$ ]]; then
                xdotool windowmove $win_id $pos $win_posY
            elif [[ "$direction" =~ ^(top|bottom)$ ]]; then
                xdotool windowmove $win_id $win_posX $pos
            fi
        done
    else
        pos=${sequence[-1]}
        if [[ "$direction" =~ ^(left|right)$ ]]; then
            xdotool windowmove $win_id $pos $win_posY
        elif [[ "$direction" =~ ^(top|bottom)$ ]]; then
            xdotool windowmove $win_id $win_posX $pos
        fi
    fi

    # In case we hid the window, try to give focus to whatever is
    # underneath the cursor.
    if [ $hide -eq 0 ]; then
        eval $(xdotool getmouselocation --shell)
        xdotool windowactivate $WINDOW > /dev/null 2>&1
    fi
}


function toggle() {
    # Called by trap once we receive a SIGUSR1

    if [ $_is_hidden -eq 0 ]; then
        hide_window 1
    else
        hide_window 0
    fi
}


function serve_region() {
    # Check the cursors location and act accordingly

    local _hide=0
    while true; do
        # Get cursor x, y position and active window
        eval $(xdotool getmouselocation --shell)

        # Test if the cursor is within the region
        if [ $X -ge $minX -a $X -le $maxX ] \
                && [ $Y -ge $minY -a $Y -le $maxY ]; then
            _hide=1
        else
            _hide=0
        fi

        # Don't hide if the cursor is still above the window
        if [ $_is_hidden -ne 0 ] \
                && [ $_hide -eq 0 ] \
                && [ $WINDOW -eq $win_id ]; then
            _hide=1
        fi

        # Only do something if necessary
        if [ $_is_hidden -ne $_hide ]; then
            hide_window $_hide
        fi

        # Cut some slack
        sleep $interval
    done
}


function serve_signal() {
    # Wait for a SIGUSR1 signal

    # Save our pid into a file so the --toggle option
    # can easily access it
    echo "$$" > /tmp/hideIt-${win_id}.pid

    trap toggle SIGUSR1
    while true; do
        read
    done

}


function serve_xev() {
    xev -id $win_id -event mouse | while read line; do
        if [[ "$line" =~ ^EnterNotify.* ]]; then
            hide_window 1
        elif [[ "$line" =~ ^LeaveNotify.* ]]; then
            hide_window 0
        fi
    done
}


function restore() {
    # Called by trap once we receive an EXIT

    rm "$_pid_file"

    if [ $_is_hidden -eq 0 ]; then
        printf "Restoring original window position...\n"
        hide_window 1
    fi

    exit 0
}


function main() {
    # Entry point for hideIt

    # Parse all the args!
    argparse "$@"

    printf "Searching window...\n"
    fetch_window_id
    if [[ ! $win_id =~ [0-9]+ ]]; then
        printf "No window found!\n" 1>&2
        exit 1
    else
        printf "Found window with id: $win_id\n"
    fi

    if [ $toggle -eq 0 ]; then
        toggle_instance
        exit 0
    fi

    printf "Fetching window dimensions...\n"
    fetch_window_dimensions 0

    printf "Fetching screen dimensions...\n"
    fetch_screen_dimensions

    trap restore EXIT

    printf "Initially hiding window...\n"
    hide_window 0

    if [ $signal -eq 0 ]; then
        printf "Waiting for SIGUSR1...\n"
    elif [ $_has_region -eq 0 ]; then
        printf "Defined region:\n"
        printf "  X: $minX $maxX\n"
        printf "  Y: $minY $maxY\n"
        printf "\n"

        printf "Waiting for region...\n"
    elif [ $hover -eq 0 ]; then
        printf "Waiting for hover...\n"
    fi

    # Start observing
    if [ $_has_region -eq 0 ]; then
        serve_region
    elif [ $signal -eq 0 ]; then
        serve_signal
    elif [ $hover -eq 0 ]; then
        serve_xev
    fi
}

# Lets do disss!
main "$@"
