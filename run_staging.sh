#!/bin/bash

# Section 1: Build/Install
# This section is for first-time setup and installations.

install_dependencies() {
    install_ubuntu() {
        echo "Updating system packages..."
        sudo apt update
        echo "Installing required packages..."
        sudo apt install --assume-yes make build-essential git clang curl libssl-dev llvm libudev-dev protobuf-compiler tmux libgmp-dev
    }

    # Detect OS and call the appropriate function
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        install_ubuntu
    else
        echo "Unsupported operating system."
        exit 1
    fi

    # Install rust and cargo
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y

    # Update your shell's source to include Cargo's path
    source "$HOME/.cargo/env"
}

# Call install_dependencies only if it's the first time running the script
if [ ! -f ".dependencies_installed" ]; then
    install_dependencies
    touch .dependencies_installed
fi


# Section 2: Test/Run
# This section is for running and testing the setup.

# Create a coldkey for the owner role
wallet=${1:-owner}

# Logic for setting up and running the environment
setup_environment() {
    # Clone subtensor and enter the directory
    if [ ! -d "subtensor" ]; then
        git clone https://github.com/opentensor/subtensor.git
    fi
    cd subtensor
    git pull

    # Update to the nightly version of rust
    ./scripts/init.sh

    cd ..

    # Install the zkp-subnet python package
    python3 -m pip install -e .

    # Create and set up wallets
    # This section can be skipped if wallets are already set up
    if [ ! -f ".wallets_setup" ]; then
        btcli wallet new_coldkey --wallet.name $wallet --no_password --no_prompt
        btcli wallet new_coldkey --wallet.name miner --no_password --no_prompt
        btcli wallet new_hotkey --wallet.name miner --wallet.hotkey default --no_prompt
        btcli wallet new_coldkey --wallet.name validator --no_password --no_prompt
        btcli wallet new_hotkey --wallet.name validator --wallet.hotkey default --no_prompt
        touch .wallets_setup
    fi

}

# Call setup_environment every time
setup_environment 

## Setup localnet
# assumes we are in the zkp-subnet/ directory
# Initialize your local subtensor chain in development mode. This command will set up and run a local subtensor network.
cd subtensor

# Start a new tmux session and create a new pane, but do not switch to it
cargo build --release --features pow-faucet runtime-benchmarks
echo "BUILD_BINARY=0 BT_DEFAULT_TOKEN_WALLET=$(cat ~/.bittensor/wallets/$wallet/coldkeypub.txt | grep -oP '"ss58Address": "\K[^"]+') bash scripts/localnet.sh" >> setup_and_run.sh
chmod +x setup_and_run.sh
tmux new-session -d -s localnet -n 'localnet'
tmux send-keys -t localnet 'bash ../subtensor/setup_and_run.sh' C-m

# Notify the user
echo ">> localnet.sh is running in a detached tmux session named 'localnet'"
echo ">> You can attach to this session with: tmux attach-session -t localnet"

# Register a subnet (this needs to be run each time we start a new local chain)
btcli subnet create --wallet.name $wallet --wallet.hotkey default --subtensor.chain_endpoint ws://127.0.0.1:9946 --no_prompt

# Transfer tokens to miner and validator coldkeys
export BT_MINER_TOKEN_WALLET=$(cat ~/.bittensor/wallets/miner/coldkeypub.txt | grep -oP '"ss58Address": "\K[^"]+')
export BT_VALIDATOR_TOKEN_WALLET=$(cat ~/.bittensor/wallets/validator/coldkeypub.txt | grep -oP '"ss58Address": "\K[^"]+')

btcli wallet transfer --subtensor.network ws://127.0.0.1:9946 --wallet.name $wallet --dest $BT_MINER_TOKEN_WALLET --amount 1000 --no_prompt
btcli wallet transfer --subtensor.network ws://127.0.0.1:9946 --wallet.name $wallet --dest $BT_VALIDATOR_TOKEN_WALLET --amount 10000 --no_prompt

# Register wallet hotkeys to subnet
btcli subnet register --wallet.name miner --netuid 1 --wallet.hotkey default --subtensor.chain_endpoint ws://127.0.0.1:9946 --no_prompt
btcli subnet register --wallet.name validator --netuid 1 --wallet.hotkey default --subtensor.chain_endpoint ws://127.0.0.1:9946 --no_prompt

# Add stake to the validator
btcli stake add --wallet.name validator --wallet.hotkey default --subtensor.chain_endpoint ws://127.0.0.1:9946 --amount 10000 --no_prompt

# Ensure both the miner and validator keys are successfully registered.
btcli subnet list --subtensor.chain_endpoint ws://127.0.0.1:9946
btcli wallet overview --wallet.name validator --subtensor.chain_endpoint ws://127.0.0.1:9946 --no_prompt
btcli wallet overview --wallet.name miner --subtensor.chain_endpoint ws://127.0.0.1:9946 --no_prompt

cd ..


# Check if inside a tmux session
if [ -z "$TMUX" ]; then
    # Start a new tmux session and run the miner in the first pane
    tmux new-session -d -s bittensor -n 'miner' 'make miner-staging WALLET_NAME=miner HOTKEY_NAME=default'
    
    # Split the window and run the validator in the new pane
    tmux split-window -h -t bittensor:miner 'make validator-staging WALLET_NAME=miner HOTKEY_NAME=default'
    
    # Attach to the new tmux session
    tmux attach-session -t bittensor
else
    # If already in a tmux session, create two panes in the current window
    tmux split-window -h 'make miner-staging WALLET_NAME=miner HOTKEY_NAME=default'
    tmux split-window -v -t 0 'make validator-staging WALLET_NAME=miner HOTKEY_NAME=default'
fi
