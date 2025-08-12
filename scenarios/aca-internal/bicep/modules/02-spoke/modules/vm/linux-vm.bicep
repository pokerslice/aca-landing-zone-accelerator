targetScope = 'resourceGroup'

// ------------------
//    PARAMETERS
// ------------------

param vmName string
param vmSize string

param vmVnetName string
param vmSubnetName string
param vmSubnetAddressPrefix string
param vmNetworkSecurityGroupName string
param vmNetworkInterfaceName string

param vmAdminUsername string

@secure()
param vmAdminPassword string

@secure()
param vmSshPublicKey string

@description('Type of authentication to use on the Virtual Machine. SSH key is recommended.')
@allowed([
  'sshPublicKey'
  'password'
])
param vmAuthenticationType string = 'password'

@description('Optional. The tags to be assigned to the created resources.')
param tags object = {}

param location string = resourceGroup().location


// ------------------
// VARIABLES
// ------------------

var linuxConfiguration = {
  disablePasswordAuthentication: true
  ssh: {
    publicKeys: [
      {
        path: '/home/${vmAdminUsername}/.ssh/authorized_keys'
        keyData: vmSshPublicKey
      }
    ]
  }
}

// ------------------
// RESOURCES
// ------------------

resource vmNetworkSecurityGroup 'Microsoft.Network/networkSecurityGroups@2020-06-01' = {
  name: vmNetworkSecurityGroupName
  location: location
  tags: tags
  properties: {
    securityRules: []
  }
}

resource vmSubnet 'Microsoft.Network/virtualNetworks/subnets@2020-11-01' = {
  name: '${vmVnetName}/${vmSubnetName}'
  properties: {
    addressPrefix: vmSubnetAddressPrefix
    networkSecurityGroup: {
      id: vmNetworkSecurityGroup.id
    }
  }
}

resource vmNetworkInterface 'Microsoft.Network/networkInterfaces@2021-02-01' = {
  name: vmNetworkInterfaceName
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: vmSubnet.id
          }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2021-03-01' = {
  name: vmName
  location: location
  tags: tags
  properties: {
    osProfile: {
      computerName: vmName
      adminUsername: vmAdminUsername
      adminPassword: ((vmAuthenticationType == 'password') ? vmAdminPassword : null)
      linuxConfiguration: ((vmAuthenticationType == 'password') ? null : linuxConfiguration)
    }
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Standard_LRS'
        }
      }
      imageReference: {
        publisher: 'Canonical'
        offer: 'UbuntuServer'
        sku: '18.04-LTS'
        version: 'latest'
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: vmNetworkInterface.id
        }
      ]
    }
  }
}

resource ghRunnerExt 'Microsoft.Compute/virtualMachines/extensions@2021-04-01' = {
  name: '${vm.name}/gh-runner'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Extensions'
    type: 'CustomScript'
    typeHandlerVersion: '2.1'
    autoUpgradeMinorVersion: true
    settings: {
      commandToExecute: 'bash -c "chmod +x /tmp/bootstrap-gh-runner.sh && /tmp/bootstrap-gh-runner.sh"'
      fileUris: []
    }
    protectedSettings: {
      script: '''
#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${ghRepoUrl}"
RUNNER_NAME="${ghRunnerName}-$(hostname)"
RUNNER_LABELS="${ghRunnerLabels}"
RUNNER_ENV="${ghEnvironment}"
REG_TOKEN="${ghRunnerRegToken}"

# --- basic packages
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -y
sudo apt-get install -y curl jq tar apt-transport-https ca-certificates lsb-release gnupg

# --- Docker (required for build/push)
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
  sudo usermod -aG docker $SUDO_USER || true
fi

# --- Azure CLI (so jobs can az login with OIDC)
if ! command -v az >/dev/null 2>&1; then
  curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
fi

# --- Create runner dir
RUNNER_DIR="/opt/github-runner"
sudo mkdir -p "$RUNNER_DIR"
sudo chown "$SUDO_USER":"$SUDO_USER" "$RUNNER_DIR"
cd "$RUNNER_DIR"

# --- Download latest runner (x64)
LATEST_URL=$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | jq -r '.assets[] | select(.name|test("linux-x64.*\\.tar\\.gz$")).browser_download_url')
curl -fsSL "$LATEST_URL" -o actions-runner.tar.gz
tar xzf actions-runner.tar.gz
rm -f actions-runner.tar.gz

# --- Configure as ephemeral runner bound to environment (uses short-lived REG_TOKEN)
sudo -u "$SUDO_USER" ./config.sh \
  --url "$REPO_URL" \
  --token "$REG_TOKEN" \
  --name "$RUNNER_NAME" \
  --labels "$RUNNER_LABELS" \
  --ephemeral \
  --unattended \
  --replace \
  --runnergroup "Default" \
  --work "_work" \
  --disableupdate

# GitHub service scripts
sudo ./svc.sh install
sudo systemctl daemon-reload

# Ensure environment is respected at run time (GitHub picks env via workflow job selector;
# we add a note here for clarity; runner itself does not store env binding beyond labels)
echo "Runner installed: $RUNNER_NAME with labels: $RUNNER_LABELS"

# Start service
sudo ./svc.sh start

# --- Private DNS sanity for ACR private endpoint (optional quick check)
getent hosts crlzaacaudri76ukdevneu.azurecr.io || true
      '''
    }
  }
}

