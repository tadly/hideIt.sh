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
WIN_ID=""
WIN_NAME=""
WIN_CLASS=""
WIN_INSTANCE=""
WAIT=1

WIN_WIDTH=""
WIN_HEIGHT=""
WIN_POSX=""
WIN_POSY=""

SCREEN_WIDTH=""
SCREEN_HEIGHT=""

MINX=""
MINY=""
MAXX=""
MAXY=""

HOVER=1
SIGNAL=1
INTERVAL=1
PEEK=3
DIRECTION="left"
STEPS=3
NO_TRANS=1
TOGGLE=1
TOGGLE_PEEK=1

_IS_HIDDEN=1
_DOES_PEEK=0
_HAS_REGION=1
_WAIT_PID=""
_PID_FILE=""


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
    printf " -w, --wait\n"
    printf "   Wait until a matching window was found.\n"
    printf "   This will check once every second.\n"
    printf "\n"
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
    printf "   direction in which to move the window.\n"
    printf "   Defaults to left.\n"
    printf "\n"
    printf " -s, --steps [amount]\n"
    printf "   steps in pixel used to move the window. The higher the value,\n"
    printf "   the faster it will move at the cost of smoothness.\n"
    printf "   Defaults to 3.\n"
    printf "\n"
    printf " -T, --no-trans\n"
    printf "   Turn of the transition effect.\n"
    printf "\n"
    printf " -t, --toggle\n"
    printf "   Send a SIGUSR1 signal to the process matching the same window.\n"
    printf "   This will toggle the visibility of the window."
    printf "\n\n"
    printf " -P, --toggle-peek\n"
    printf "   Send a SIGUSR2 signal to the process matching the same window.\n"
    printf "   This will toggle the hidden state of the window if --peek is greater 0."
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
                WIN_NAME="$2"
                shift
                ;;
            "-C"|"--class")
                WIN_CLASS="$2"
                shift
                ;;
            "-I"|"--instance")
                WIN_INSTANCE="$2"
                shift
                ;;
            "--id")
                if [[ ! $2 =~ [0-9]+ ]]; then
                    printf "Invalid window id. Should be a number.\n" 1>&2
                    exit 1
                fi

                WIN_ID="$2"
                shift
                ;;
            "-w"|"--wait")
                WAIT=0
                ;;
            "-H"|"--hover")
                HOVER=0
                ;;
            "-S"|"--signal")
                SIGNAL=0
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

                MINX=$posX
                MAXX=$((${MINX} + ${offsetX}))
                if [ $MINX -gt $MAXX ]; then
                    read MINX MAXX <<< "$MAXX $MINX"
                fi

                MINY=$posY
                MAXY=$((${MINY} + ${offsetY}))
                if [ $MINY -gt $MAXY ]; then
                    read MINY MAXY <<< "$MAXY $MINY"
                fi

                if [[ ! $MINX =~ [0-9]+ ]] || [[ ! $MINY =~ [0-9]+ ]] \
                        || [[ ! $MAXY =~ [0-9]+ ]] || [[ ! $MAXY =~ [0-9]+ ]]; then
                    printf "Missing or invalid region. See --help for usage.\n" 1>&2
                    exit 1
                fi
                _HAS_REGION=0
                shift
                ;;
            "-i"|"--interval")
                INTERVAL="$2"
                if [[ ! $INTERVAL =~ [0-9]+ ]]; then
                    printf "Interval should be a number. " 1>&2
                    exit 1
                fi
                shift
                ;;
            "-p"|"--peek")
                PEEK="$2"
                if [[ ! $PEEK =~ [0-9]+ ]]; then
                    printf "Peek should be a number. " 1>&2
                    exit 1
                fi
                shift
                ;;
            "-d"|"--direction")
                DIRECTION="$2"
                if [[ ! "$DIRECTION" =~ ^(left|right|top|bottom)$ ]]; then
                    printf "Invalid direction. See --help for usage.\n" 1>&2
                    exit 1
                fi
                shift
                ;;
            "-s"|"--steps")
                STEPS="$2"
                if [[ ! $STEPS =~ [0-9]+ ]]; then
                    printf "Steps should be a number. " 1>&2
                    exit 1
                fi
                shift
                ;;
            "-T"|"--no-trans")
                NO_TRANS=0
                ;;
            "-t"|"--toggle")
                TOGGLE=0
                ;;
            "-P"|"--toggle-peek")
                TOGGLE_PEEK=0
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
    local _names="${WIN_ID}${WIN_NAME}${WIN_CLASS}${WIN_INSTANCE}"
    if [ -z "$_names" ] && [ -z "$WIN_ID" ]; then
        printf "At least one of --name, --class, --instance or --id" 1>&2
        printf " is required!\n" 1>&2
        exit 1
    fi

    if [ $TOGGLE -ne 0 ] && [ $TOGGLE_PEEK -ne 0 ] && [ $SIGNAL -ne 0 ] \
            && [ $_HAS_REGION -ne 0 ] && [ $HOVER -ne 0 ]; then
        printf "At least one of --toggle, --signal, --hover or" 1>&2
        printf " --region is required!\n" 1>&2
        exit 1
    fi
}


function fetch_window_id() {
    # Sets the values for the following global
    #   WIN_ID

    # We already have a window id
    if [ ! -z "$WIN_ID" ]; then
        _PID_FILE="/tmp/hideIt-${WIN_ID}.pid"
        return
    fi

    local _id=-1

    # Search all windows matching the provided class
    local _tmp1=()
    if [ ! -z "$WIN_CLASS" ]; then
        _tmp1=($(xdotool search --class "$WIN_CLASS"))
        _tmp1=${_tmp1:--1}
    fi

    # Search all windows matching the provided instance
    local _tmp2=()
    if [ ! -z "$WIN_INSTANCE" ]; then
        _tmp2=($(xdotool search --classname "$WIN_INSTANCE"))
        _tmp2=${_tmp2:--1}
    fi

    # Search all windows matching the provided name (title)
    local _tmp3=()
    if [ ! -z "$WIN_NAME" ]; then
        _tmp3=($(xdotool search --name "$WIN_NAME"))
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
        WIN_ID=$_id
        _PID_FILE="/tmp/hideIt-${WIN_ID}.pid"
    fi
}


function fetch_screen_dimensions() {
    # Sets the values for the following globals
    #    SCREEN_WIDTH, SCREEN_HEIGHT

    local win_info=$(xwininfo -root)
    SCREEN_WIDTH=$(echo "$win_info" | sed -rn 's/.*Width: +([0-9]+)/\1/p')
    SCREEN_HEIGHT=$(echo "$win_info" | sed -rn 's/.*Height: +([0-9]+)/\1/p')
}


function fetch_window_dimensions() {
    # Sets the values for the following globals unless no WIN_ID exists
    #    WIN_WIDTH, WIN_HEIGHT, WIN_POSX, WIN_POSY

    if [[ ! $WIN_ID =~ [0-9]+ ]]; then
        return
    fi

    local win_info=$(xwininfo -id $WIN_ID)

    WIN_WIDTH=$(echo "$win_info" | sed -rn 's/.*Width: +([0-9]+)/\1/p')
    WIN_HEIGHT=$(echo "$win_info" | sed -rn 's/.*Height: +([0-9]+)/\1/p')

    if [ ! -z "$1" ] && [ $1 -eq 0 ]; then
        WIN_POSX=$(echo "$win_info" | \
            sed -rn 's/.*Absolute upper-left X: +(-?[0-9]+)/\1/p')
        WIN_POSY=$(echo "$win_info" | \
            sed -rn 's/.*Absolute upper-left Y: +(-?[0-9]+)/\1/p')
    fi
}


function send_signal() {
    # Send a SIGUSR1 to an active hideIt.sh instance
    # if a pid file was found.
    local signal=$1
    if [ ! -f "$_PID_FILE" ]; then
        printf "Pid file at \"${_PID_FILE}\" doesn't exist!\n" 1>&2
        exit 1
    fi

    local _pid=`cat $_PID_FILE`
    printf "Sending ${signal} to instance...\n"

    if [[ $_pid =~ [0-9]+ ]]; then
        kill -${signal} $_pid
        exit 0
    else
        printf "Invalid pid in \"${_PID_FILE}\".\n" 1>&2
        exit 1
    fi
}


function hide_window() {
    # Move the window in or out
    # Args:
    #     hide: 0 to hide, 1 to show

    local hide=$1

    # Make sure window still exists and exit if not.
    xwininfo -id $WIN_ID &> /dev/null
    if [ $? -ne 0 ]; then
        printf "Window doesn't exist anymore, exiting!\n"
        exit 0
    fi

    _IS_HIDDEN=$hide

    # Update WIN_WIDTH, WIN_HEIGHT in case they changed
    fetch_window_dimensions

    # Activate the window.
    # Should bring it to the front, change workspace etc.
    if [ $hide -ne 0 ]; then
        xdotool windowactivate $WIN_ID > /dev/null 2>&1
    fi

    # Generate the sequence used to move the window
    local to=()
    local sequence=()
    if [ "$DIRECTION" == "left" ]; then
        to=-$(($WIN_WIDTH - $PEEK))
        if [ $hide -eq 0 ]; then
            sequence=($(seq $WIN_POSX -$STEPS $to))
            sequence+=($to)
        else
            sequence=($(seq $to $STEPS $WIN_POSX))
            sequence+=($WIN_POSX)
        fi

    elif [ "$DIRECTION" == "right" ]; then
        to=$(($SCREEN_WIDTH - $PEEK))
        if [ $hide -eq 0 ]; then
            sequence=($(seq $WIN_POSX $STEPS $to))
            sequence+=($to)
        else
            sequence=($(seq $to -$STEPS $WIN_POSX))
            sequence+=($WIN_POSX)
        fi

    elif [ "$DIRECTION" == "bottom" ]; then
        to=$(($SCREEN_HEIGHT - $PEEK))
        if [ $hide -eq 0 ]; then
            sequence=($(seq $WIN_POSY $STEPS $to))
            sequence+=($to)
        else
            sequence=($(seq $to -$STEPS $WIN_POSY))
            sequence+=($WIN_POSY)
        fi

    elif [ "$DIRECTION" == "top" ]; then
        to=-$(($WIN_HEIGHT - $PEEK))
        if [ $hide -eq 0 ]; then
            sequence=($(seq $WIN_POSY -$STEPS $to))
            sequence+=($to)
        else
            sequence=($(seq $to $STEPS $WIN_POSY))
            sequence+=($WIN_POSY)
        fi
    fi

    # Actually move the window
    if [ $NO_TRANS -ne 0 ]; then
        for pos in ${sequence[@]}; do
            if [[ "$DIRECTION" =~ ^(left|right)$ ]]; then
                xdotool windowmove $WIN_ID $pos $WIN_POSY
            elif [[ "$DIRECTION" =~ ^(top|bottom)$ ]]; then
                xdotool windowmove $WIN_ID $WIN_POSX $pos
            fi
        done
    else
        pos=${sequence[-1]}
        if [[ "$DIRECTION" =~ ^(left|right)$ ]]; then
            xdotool windowmove $WIN_ID $pos $WIN_POSY
        elif [[ "$DIRECTION" =~ ^(top|bottom)$ ]]; then
            xdotool windowmove $WIN_ID $WIN_POSX $pos
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
    # Toggle the hidden state of the window

    if [ $_IS_HIDDEN -eq 0 ]; then
        hide_window 1
    else
        hide_window 0
    fi
}

function toggle_peek() {
    # Completely hide/unhide the window in case PEEK is greater 0

    if [ $PEEK -eq 0 ]; then
        return
    fi

    local _peek=$PEEK
    local _win_posx=$WIN_POSX
    local _win_posy=$WIN_POSY

    fetch_window_dimensions 0

    if [ $_DOES_PEEK -eq 0 ]; then
        _DOES_PEEK=1
        PEEK=0
    else
        _DOES_PEEK=0
    fi

    hide_window 0

    PEEK=$_peek
    WIN_POSX=$_win_posx
    WIN_POSY=$_win_posy
}

function serve_region() {
    # Check the cursors location and act accordingly

    local _hide=0
    while true; do
        if [ $_DOES_PEEK -eq 0 ]; then
            # Get cursor x, y position and active window
            eval $(xdotool getmouselocation --shell)

            # Test if the cursor is within the region
            if [ $X -ge $MINX -a $X -le $MAXX ] \
                    && [ $Y -ge $MINY -a $Y -le $MAXY ]; then
                _hide=1
            else
                _hide=0
            fi

            # Don't hide if the cursor is still above the window
            if [ $_IS_HIDDEN -ne 0 ] \
                    && [ $_hide -eq 0 ] \
                    && [ $WINDOW -eq $WIN_ID ]; then
                _hide=1
            fi

            # Only do something if necessary
            if [ $_IS_HIDDEN -ne $_hide ]; then
                hide_window $_hide
            fi
        fi

        # Cut some slack
        sleep $INTERVAL
    done
}


function serve_xev() {
    # Wait for cursor "Enter" and "Leave" events reported by
    # xev and act accordingly

    xev -id $WIN_ID -event mouse | while read line; do
        if [[ "$line" =~ ^EnterNotify.* ]]; then
            hide_window 1
        elif [[ "$line" =~ ^LeaveNotify.* ]]; then
            hide_window 0
        fi
    done
}


function restore() {
    # Called by trap once we receive an EXIT

    if [ -n "$_WAIT_PID" ]; then
        kill -- "-${_WAIT_PID}"
    fi

    if [ -f "$_PID_FILE" ]; then
        rm "$_PID_FILE"
    fi

    if [ $_IS_HIDDEN -eq 0 ]; then
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

    # If enabled, wait until a window was found.
    if [ $WAIT -eq 0 ] && [[ ! $WIN_ID =~ [0-9]+ ]]; then
        printf "Waiting for window"
        while [[ ! $WIN_ID =~ [0-9]+ ]]; do
            printf "."
            fetch_window_id
            sleep 1
        done
        printf "\n"
    fi

    if [[ ! $WIN_ID =~ [0-9]+ ]]; then
        printf "No window found!\n" 1>&2
        exit 1
    else
        printf "Found window with id: $WIN_ID\n"
    fi

    if [ $TOGGLE -eq 0 ]; then
        send_signal SIGUSR1
        exit 0
    fi

    if [ $TOGGLE_PEEK -eq 0 ]; then
        send_signal SIGUSR2
        exit 0
    fi

    printf "Fetching window dimensions...\n"
    fetch_window_dimensions 0

    printf "Fetching screen dimensions...\n"
    fetch_screen_dimensions

    trap restore EXIT

    printf "Initially hiding window...\n"
    hide_window 0

    # Save our pid into a file
    echo "$$" > /tmp/hideIt-${WIN_ID}.pid
    trap toggle_peek SIGUSR2

    # Start observing
    if [ $_HAS_REGION -eq 0 ]; then
        printf "Defined region:\n"
        printf "  X: $MINX $MAXX\n"
        printf "  Y: $MINY $MAXY\n"
        printf "\n"
        printf "Waiting for region...\n"
        serve_region &
        _WAIT_PID=$!
    elif [ $SIGNAL -eq 0 ]; then
        printf "Waiting for SIGUSR1...\n"
        trap toggle SIGUSR1
        sleep infinity &
        _WAIT_PID=$!
    elif [ $HOVER -eq 0 ]; then
        printf "Waiting for HOVER...\n"
        serve_xev &
        _WAIT_PID=$!
    fi

    if [ -n "$_WAIT_PID" ]; then
        while true; do
            wait "$_WAIT_PID"
            printf "Received signal...\n"
        done
    fi
}

# Lets do disss!
set -m
main "$@"
