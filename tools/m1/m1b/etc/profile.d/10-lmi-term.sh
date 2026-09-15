#!/bin/sh
# SPDX-License-Identifier: MIT
# lmi terminal defaults: 256-colour terminal, readable prompt, colourised ls.
# Sourced by /etc/profile for login shells (weston-terminal starts a login shell).
TERM=xterm-256color
export TERM

# dircolors: busybox ls understands LS_COLORS
LS_COLORS='di=1;34:ln=1;36:so=1;35:pi=33:ex=1;32:bd=1;33:cd=1;33:su=37;41:sg=30;43:tw=30;42:ow=34;42:*.tar=1;31:*.gz=1;31:*.zip=1;31:*.jpg=1;35:*.png=1;35:*.mp4=1;35:*.mp3=1;35:*.sh=1;32:*.c=1;33:*.h=1;33:*.py=1;33'
export LS_COLORS
alias ls='ls --color=auto'
alias ll='ls -l'
alias la='ls -la'

# show the current path in the prompt, colour the prompt marker
PS1='\[\e[1;32m\]\u@\h\[\e[0m\]:\[\e[1;34m\]$PWD\[\e[0m\]\$ '
export PS1

# a couple of niceties for a phone terminal
alias ..='cd ..'
alias grep='grep --color=auto'
