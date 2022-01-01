#!/bin/bash
#DEBUG=yes

# Log to stderr in sub-process to avoid output errors
# Mostly for SSH/shell stuff but I like it!
function errlog() {
	[[ ! -z $DEBUG ]] && (echo "MultiSeat Log: ${@}" 1>&2)
}
errlog "MultiSeat Log: Debug mode active. No commands will be executed."

# Are we sudo?
function isRoot() {
	errlog user $EUID
	if [[ ! -z $DEBUG ]]
	then
		return 0
	elif [ "$EUID" -ne 0 ]
	then
		sudo $0 $*
		return 1
	fi
}

# Do you want to reboot now?
function promptReboot() {
	errlog "write promptReboot"
}

# Renders a text based list of options that can be selected by the
# user using up, down and enter keys and returns the chosen option.
#
#   Arguments   : list of options, maximum of 256
#				 "opt1" "opt2" ...
#   Return value: selected index (0 for opt1, 1 for opt2 ...)
#
# Sourced from https://unix.stackexchange.com/a/415155/140671
# By https://unix.stackexchange.com/users/219724/alexander-klimetschek
function select_option {

	# little helpers for terminal print control and key input
	ESC=$( printf "\033")
	cursor_blink_on()	{ printf "$ESC[?25h"; }
	cursor_blink_off()	{ printf "$ESC[?25l"; }
	cursor_to()			{ printf "$ESC[$1;${2:-1}H"; }
	print_option()		{ printf "   $1 "; }
	print_selected()	{ printf "  $ESC[7m $1 $ESC[27m"; }
	get_cursor_row()	{ IFS=';' read -sdR -p $'\E[6n' ROW COL; echo ${ROW#*[}; }
	key_input()			{ read -s -n3 key 2>/dev/null >&2
						 if [[ $key = $ESC[A ]]; then echo up;	fi
						 if [[ $key = $ESC[B ]]; then echo down;  fi
						 if [[ $key = ""	 ]]; then echo enter; fi; }

	# initially print empty new lines (scroll down if at bottom of screen)
	for opt; do printf "\n"; done

	# determine current screen position for overwriting the options
	local lastrow=`get_cursor_row`
	local startrow=$(($lastrow - $#))

	# ensure cursor and input echoing back on upon a ctrl+c during read -s
	trap "cursor_blink_on; stty echo; printf '\n'; exit" 2
	cursor_blink_off

	local selected=0
	while true; do
		# print options by overwriting the last lines
		local idx=0
		for opt; do
			cursor_to $(($startrow + $idx))
			if [ $idx -eq $selected ]; then
				print_selected "$opt"
			else
				print_option "$opt"
			fi
			((idx++))
		done

		# user key control
		case `key_input` in
			enter) break;;
			up)	((selected--));
				   if [ $selected -lt 0 ]; then selected=$(($# - 1)); fi;;
			down)  ((selected++));
				   if [ $selected -ge $# ]; then selected=0; fi;;
		esac
	done

	# cursor position back to normal
	cursor_to $lastrow
	printf "\n"
	cursor_blink_on

	return $selected
}

# Don't need if I just print the commands to console... no auto sudo ftw?
#isRoot || exit

#######
# Check for active Multiseat.
# If multiseat is active, kill it with fire
#######

if [[ $(loginctl list-seats | tail -n1 | awk '{print $1}') -gt 1 ]]
then
	# More than 1 seat active.
	echo "There is more than 1 active seat."
	echo "Restoring all to seat0"

	# reset all to seat0 & reboot?
	echo "Command to clear all seats:"
	echo "sudo loginctl flush-devices"
	echo "Then reboot to apply. Restarting Xorg might work too."
	exit
fi

######
# Only 1 active seat
# How many seats can we have?
######

# List GPUs and USB device
IFS=$'\n' gpuList=($(lspci | grep "VGA compatible controller"))
IFS=$'\n' usbList=($(lsusb | grep -v "Linux Foundation"))

if [[ ${#gpuList[@]} -eq 1 ]]
then
	# Only 1 card found!
	echo -e "MultiSeat: Only 1 GPU. Cannot configure multiseat this way." 1>&2
	exit
fi

unset seats

if [[ ! -z $DISPLAY ]] && command -v zenity &>/dev/null
then
	# GUI!
	seats=$(zenity \
	--title "LoginCTL Quick Set" \
	--text "How many Seats?" \
	--scale \
	--value 1 \
	--min-value 1 \
	--max-value ${#gpuList[@]} \
	--width 350 \
	--height 350 \
	2>/dev/null)
	if [[ $? -ne 0 ]] || [[ -z seats ]]; then exit; fi
else
	# Text!
	seatList=($(seq 1 ${#gpuList[@]}))
	echo "How many seats do you want?"
	select_option "${seatList[@]}"
	seats=$(($? + 1))
fi

if [[ $seats -eq 1 ]]
then
	# Wants 1 seat
	errlog "Requested seats: $seats. Nothing to do!"
	exit
fi

#declare -A seatDeviceList

# Wants multiple seats.
errlog "Requested seats:" ${seats}
for i in $(seq 1 $((${seats} -1)))
do
	# List available GPUS
	availableCards=""

	unset gui
	# Pick from remaining cards.
	if [[ ! -z $DISPLAY ]] && command -v zenity &>/dev/null
	then
		# GUI!
		gpu=$(
		for key in ${!gpuList[@]}
		do
			echo $key
			echo ${gpuList[$key]}
		done | zenity \
		--title "SEAT${i}" \
		--text "Which GPU for seat${i}?" \
		--list \
		--column "#" \
		--column "lspci | grep \"VGA compatible controller\"" \
		--hide-column 1 \
		--width 1024 \
		--height 320 \
		2>/dev/null)
		if [[ $? -ne 0 ]] || [[ -z gpu ]]; then exit; fi
	else
		# Text!
		echo "- - - SEAT${i} - - -"
		echo "Select GPU for seat${i}:"
		select_option "${gpuList[@]}"
		gpu=$?
	fi

	# Store selection
	targetGPU="${gpuList[$gpu]}"
	errlog "Requested Card: ${targetGPU}"
	unset newGPUList

	# Remove selection from available list.
	for j in "${!gpuList[@]}"; do
		if [ "${gpuList[j]}" == "${targetGPU}" ]
		then
			# Extract cards from PCI ID
			gpuPCI=$(echo "${targetGPU}" | awk '{print $1}')
			#sndPCI=$(lspci | grep ${gpuPCI%.*} | grep " Audio device: " | awk '{print $1}')

			# Get drm, framebuffer and sound card
			targetGPU=`loginctl seat-status seat0 | grep "${gpuPCI}/drm/card.\$" | awk -F'├─' '{print $2}' | awk -F'.0/drm/' '{print $1}'`

			# Assign card to current seat.
			for dev in $(loginctl seat-status seat0 | grep -v "│" | grep "${targetGPU}" | awk -F'├─' '{print $2}')
			do
				errlog "Linking ${dev} to seat${i}"
				seatDeviceList[${i}]+="${dev} "
			done
		else
			# Not a selected GPU, add to new list.
			newGPUList=(${newGPUList[@]} "${gpuList[j]}")
			errlog "Remaining GPU: ${gpuList[j]}"
		fi
	done

	# Update GPU list indexes
	gpuList=(${newGPUList[@]})

	while :;
	do
		unset gui
		usbList2=(${usbList[@]} "refresh" "done")
		# Pick from remaining cards.
		if [[ ! -z $DISPLAY ]] && command -v zenity &>/dev/null
		then
			# GUI!
			hub=$(
			for key in ${!usbList2[@]}
			do
				echo $key
				echo ${usbList2[$key]}
			done | zenity \
			--title "SEAT${i}" \
			--text "Select a USB hub for seat${i}?" \
			--list \
			--column "#" \
			--column "lsusb | grep -v \"Linux Foundation\"" \
			--hide-column 1 \
			--width 1024 \
			--height 320 \
			2>/dev/null)
			if [[ $? -ne 0 ]] || [[ -z hub ]]; then exit; fi
		else
			# Text!
			echo "Select USB hub (via Device) for seat${i}:"
			select_option "${usbList2[@]}"
			hub=$?

		fi

		[ "${usbList2[$hub]}" == "done" ] && break

		if [ "${usbList2[$hub]}" == "refresh" ]
		then
			# Rebuild list, if you wanna screw with what's plugged in where.
			IFS=$'\n' usbList=($(lsusb | grep -v "Linux Foundation"))
		else
			targetHUB="${usbList[$hub]}"

			errlog "Requested HUB: ${targetHUB}"

			stripHUB="$(echo ${targetHUB} | awk '{print $2}')"
			errlog "Remove ${stripHUB}"

			unset newHUBList
			unset hubID

			# Remove selection from available list.
			for j in "${!usbList[@]}"; do
				if [[ ${usbList[j]} == *"Bus ${stripHUB}"* ]]
				then
					hubID=$(echo ${stripHUB} | sed 's/^0*//g')

					dev=`loginctl seat-status seat0 | grep "/usb${hubID}\$" | awk -F'├─' '{print $2}'`

					# This item is not yet in the attach list.
					if [[ ! ${seatDeviceList[${i}]} =~ "${dev}" ]]
					then
						seatDeviceList[${i}]+="${dev} "
					fi
				else
					newHUBList=(${newHUBList[@]} "${usbList[j]}")
					errlog "Remaining Devices: ${usbList[j]}"
				fi
			done
			# Update USB Hub list indexes
			usbList=(${newHUBList[@]})
		fi
	done
done

# LoginCTL is wonky?
# Randomly does nothing despite command not throwing an error?
#seatDeviceList=( $(shuf -e "${seatDeviceList[@]}") )

for key in ${!seatDeviceList[@]}
do
	for dev in $(echo ${seatDeviceList[$key]} | sed 's/ /\n/g')
	do
		errlog "seat${key} <- $dev"
	done
done

# Save myself the hassle!
echo "Commands to configure additional seats:"
for key in ${!seatDeviceList[@]}
do
	echo -n "sudo loginctl attach seat${key} ${seatDeviceList[$key]}&& "
done
echo -e "\nReboot to apply."
