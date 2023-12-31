#%- if not upgrade_script -%#
# (C) 2023–present Bartosz Sławecki (bswck)
#
# This script is run on every copier task event.
# Implemented as a workaround for copier-org/copier#240.
# https://github.com/copier-org/copier/issues/240
#
# Usage:
# $ copier copy --trust --vcs-ref HEAD gh:{{skeleton}} project
# Later on, this script will be included in your project and run automatically within:
# $ poe skeleton upgrade

# shellcheck shell=bash
# shellcheck disable=SC1054,SC1073,SC2005,SC1083

set -eEuo pipefail

setup_task_event() {
    # By default use PPID not to overlap with other running copier processes
    export SKELETON_COMMAND
    note "(Setting up task event)"
    info "${GREY}Skeleton command:$NC ${SKELETON_COMMAND:="copy"}"
    info "${GREY}Project path key:$NC ${PROJECT_PATH_KEY:="${PPID}_skeleton_project_path"}"

    # It is a temporary directory that copier uses before or after updating
    set +eE
    if test "$(pwd | grep "^/tmp/")"
    then
        # Before update
        if test "$(pwd | grep "old_copy")"
        then
            export TASK_EVENT="CHECKOUT_LAST_SKELETON"
            # After update
        else
            export TASK_EVENT="CHECKOUT_PROJECT"
        fi
    else
        # Export the project path to parent process
        silent redis-cli set "$PROJECT_PATH_KEY" "$(pwd)"

        # Does this repository exist remotely?
        silent git ls-remote "{{repo_url}}" HEAD
        if test $? = 0 && test "${LAST_REF:=""}"  # Missing $LAST_REF means we are not updating.
        then
            # Let the parent process know what is the new skeleton revision
            set -eE
            silent redis-cli set "$NEW_REF_KEY" "{{sref}}"
            export TASK_EVENT="UPGRADE"
            export BRANCH
            BRANCH="$(git rev-parse --abbrev-ref HEAD)"
        else
            # Integrate the skeleton for the first time or even create a new repository
            export TASK_EVENT="COPY"
        fi
    fi
    set -eE

    determine_project_path
    info "${GREY}Task stage:$NC $TASK_EVENT"
    info "${GREY}Last skeleton revision:$NC ${LAST_REF:-"N/A"}"
    info "${GREY}Project path:$NC ${PROJECT_PATH:-"N/A"}"
    info "${GREY}Runner ID:$NC $PPID"
    echo
}

run_copier_hook() {
    # Run a temporary hook that might generate LICENSE file and other stuff
    note "Running copier hook..."
    python copier_hook.py
    info "Copier hook exited with code $BOLD$?$NC."
    note "Removing copier hook..."
    rm copier_hook.py || (error $? "Failed to remove copier hook.")
}

setup_poetry_virtualenv() {
    # Set up Poetry virtualenv. This is needed for copier to work flawlessly.
    #% if not ctt_mode %#
    note "Setting Python version to ${PYTHON_VERSION:=$(cat .python-version)}..."
    poetry env use "$PYTHON_VERSION"
    echo
    note "Running Poetry installation for the $TASK_EVENT routine..."
    if test "$TASK_EVENT" = "COPY"
    then
        poetry update || (error $? "Failed to install dependencies.")
    fi
    poetry lock --no-update
    #% else %#
    :
    #% endif %#
    clear
}

after_copy() {
    # This is the first time the skeleton is integrated into the project.
    note "Setting up the project..."
    echo
    setup_poetry_virtualenv
    run_copier_hook
    silent rm -f ./handle-task-event
    #% if not ctt_mode %#
    if test "$(git rev-parse --show-toplevel 2> /dev/null)" != "$(pwd)"
    then
        BRANCH="main"
        echo
        note "Initializing git repository..."
        silent git init .
        silent git branch -M "$BRANCH"
        info "Main branch: $BRANCH"
        gh repo create {{gh.repo_args}}
        git remote add origin "{{repo_url}}.git"
        CREATED=1
    else
        BRANCH="$(git rev-parse --abbrev-ref HEAD)"
    fi
    echo
    #%- if use_precommit %#
    note "Installing pre-commit..."
    silent poetry run pre-commit install --hook-type pre-commit --hook-type pre-push
    success "Pre-commit installed."
    #%- endif %#
    COMMIT_MSG="Copy {{snref}}"
    REVISION_PARAGRAPH="Skeleton revision: {{skeleton_rev}}"
    silent git add .
    silent git commit --no-verify -m "$COMMIT_MSG" -m "$REVISION_PARAGRAPH"
    echo
    if test "${CREATED:-0}" != 0
    then
        silent git push --no-verify -u origin "$BRANCH"
        setup_gh && echo
    else
        silent git revert --no-commit HEAD
        info "Reverted the latest commit to complete the integration process."
        echo "Patch your files and commit your changes with the --am option"
        echo "to inform copier what needs to be kept."
        echo
        echo "Then run:"
        echo "💲 poe skeleton upgrade"
    fi
    #% endif %#
}

after_checkout_last_skeleton() {
    run_copier_hook
}

before_update() {
    :
}

after_update() {
    setup_poetry_virtualenv
    run_copier_hook
    #% if use_precommit %#
    poetry run pre-commit install --hook-type pre-commit --hook-type pre-push
    #% else %#
    poetry run pre-commit uninstall
    #% endif %#
}

before_checkout_project() {
    :
}

after_checkout_project() {
    run_copier_hook
}

handle_task_event() {
    if test "$TASK_EVENT" = "COPY"
    then
        clear
        note "COPY ROUTINE: Copying the skeleton."
        after_copy
        determine_project_path
        success "COPY ROUTINE COMPLETE."
        echo
        #% if not ctt_mode %#
        success "Done! 🎉"
        info "Your repository is now set up at ${BOLD}{{repo_url}}$NC"
        echo -e "  💲 ${BOLD}cd $PROJECT_PATH$NC"
        echo
        echo "Happy coding!"
        echo -e "$GREY-- bswck$NC"
        silent redis-cli del "$PROJECT_PATH_KEY"
        #% endif %#
    elif test "$TASK_EVENT" = "CHECKOUT_LAST_SKELETON"
    then
        info "UPGRADE ALGORITHM [1/3]: Checked out the last used skeleton before update."
        after_checkout_last_skeleton
        before_update
        success "UPGRADE ALGORITHM [1/3] COMPLETE."
        echo
    elif test "$TASK_EVENT" = "UPGRADE"
    then
        info "UPGRADE ALGORITHM [2/3]: Overwrote the old skeleton before checking out the project."
        note "Re-setting up the project..."
        after_update
        before_checkout_project
        success "UPGRADE ALGORITHM [2/3] COMPLETE."
        echo
    elif test "$TASK_EVENT" = "CHECKOUT_PROJECT"
    then
        info "UPGRADE ALGORITHM [3/3]: Checked out the project."
        after_checkout_project
        success "UPGRADE ALGORITHM [3/3] COMPLETE."
    fi
}
#%- endif %#
#%- if upgrade_script %#
# Automatically copied from {{skeleton_url}}/tree/{{sref}}/handle-task-event.sh
#%- endif %#
# Comms
BOLD="\033[1m"
RED="\033[0;31m"
GREEN="\033[0;32m"
BLUE="\033[0;34m"
GREY="\033[0;90m"
NC="\033[0m"

UI_INFO="${BLUE}🛈${NC}"
UI_NOTE="${GREY}→${NC}"
UI_TICK="${GREEN}✔${NC}"
UI_CROSS="${RED}✘${NC}"

info() {
    echo -e "$UI_INFO $*"
}

note() {
    echo -e "$UI_NOTE $GREY$*$NC"
}

success() {
    echo -e "$UI_TICK $*"
}

silent() {
    "$1" "${@:2}" > /dev/null 2>&1
}

error() {
    local CODE=$1
    echo -e "$UI_CROSS ${*:2}" >&2
    return "$CODE"
}

setup_gh() {
    note "Calling GitHub setup hooks..."
    #%- if public %#
    echo
    supply_keys
    #%- endif %#
}

determine_project_path() {
    # Determine the project path set by the preceding copier task process
    export PROJECT_PATH
    PROJECT_PATH=$(redis-cli get "$PROJECT_PATH_KEY")
}

ensure_gh_environment() {
    # Ensure that the GitHub environment exists
    silent echo "{{gh.ensure_env}}" || error 0 "Failed to ensure GitHub environment $BLUE$1$NC exists."
}

supply_keys() {
    local SMOKESHOW_KEY
    local CODECOV_TOKEN
    local ENV_NAME="Upload Coverage"
    note "Creating a GitHub Actions environment $BLUE$ENV_NAME$GREY if necessary..."
    ensure_gh_environment "$ENV_NAME"
    success "Environment $BLUE$ENV_NAME$NC exists."
    echo
    note "Checking if Smokeshow secret key needs to be created..."
    set +eE
    if test "$(gh secret list -e "$ENV_NAME" | grep -o SMOKESHOW_AUTH_KEY)"
    then
        info "Smokeshow secret key already set."
    else
        info "Smokeshow secret key does not exist yet."
        note "Creating Smokeshow secret key..."
        SMOKESHOW_KEY=$(smokeshow generate-key | grep SMOKESHOW_AUTH_KEY | grep -oP "='\K[^']+")
        gh secret set SMOKESHOW_AUTH_KEY --env "$ENV_NAME" --body "$SMOKESHOW_KEY" 2> /dev/null || error 0 "Failed to set Smokeshow secret key."
        echo
    fi
    note "Setting codecov secret token..."
    CODECOV_TOKEN=$(keyring get codecov token)
    gh secret set CODECOV_TOKEN --env "$ENV_NAME" --body "$CODECOV_TOKEN" 2> /dev/null || error 0 "Failed to set codecov secret token."
    set -eE
}
#%- if upgrade_script %#
# End of copied code
#%- endif %#
