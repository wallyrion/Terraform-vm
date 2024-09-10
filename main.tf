provider "azurerm" {
  features {}
}

resource "random_id" "rg_suffix" {
  byte_length = 4
}

resource "azurerm_resource_group" "rg" {
  name     = "seq-rg-${random_id.rg_suffix.hex}"
  location = "East US"
}

resource "azurerm_virtual_network" "vnet" {
  name                = "seq-vnet-${random_id.rg_suffix.hex}"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_subnet" "subnet" {
  name                 = "seq-subnet-${random_id.rg_suffix.hex}"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_public_ip" "public_ip" {
  name                = "seq-pip-${random_id.rg_suffix.hex}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Dynamic"
}

resource "azurerm_network_interface" "nic" {
  name                = "seq-nic-${random_id.rg_suffix.hex}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.subnet.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_network_interface" "nic_with_pip" {
  name                = "seq-nic-with-pip-${random_id.rg_suffix.hex}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "external"
    subnet_id                     = azurerm_subnet.subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.public_ip.id
  }
}

resource "azurerm_virtual_machine" "vm" {
  name                  = "seq-vm-${random_id.rg_suffix.hex}"
  location              = azurerm_resource_group.rg.location
  resource_group_name   = azurerm_resource_group.rg.name
  network_interface_ids = [azurerm_network_interface.nic_with_pip.id]
  vm_size               = "Standard_B1s" # Fits in the free tier

  storage_os_disk {
    name              = "seq_os_disk-${random_id.rg_suffix.hex}"
    caching           = "ReadWrite"
    create_option     = "FromImage"
    managed_disk_type = "Standard_LRS"
  }

  storage_image_reference {
    publisher = "Canonical"
    offer     = "UbuntuServer"
    sku       = "18.04-LTS"
    version   = "latest"
  }

  os_profile {
    computer_name  = "seqvm-${random_id.rg_suffix.hex}"
    admin_username = "azureuser"
    custom_data    = filebase64("${path.module}/cloud-init.txt")
  }

  os_profile_linux_config {
    disable_password_authentication = true

    ssh_keys {
      path     = "/home/azureuser/.ssh/authorized_keys"
      key_data = file("${path.module}/terraform_azure.pub")
    }
  }

  tags = {
    environment = "testing"
  }
}

resource "azurerm_network_security_group" "nsg" {
  name                = "seq-nsg-${random_id.rg_suffix.hex}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  security_rule {
    name                       = "allow_ssh"
    priority                   = 1000
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow_http"
    priority                   = 1010
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow_experiment_bj"
    priority                   = 1020
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "5567"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}


resource "azurerm_network_interface_security_group_association" "nic_nsg" {
  network_interface_id      = azurerm_network_interface.nic_with_pip.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

resource "null_resource" "install_docker" {
  depends_on = [azurerm_virtual_machine.vm, azurerm_public_ip.public_ip]

  provisioner "local-exec" {
    command = "echo ${azurerm_public_ip.public_ip.ip_address}"
  }

  provisioner "remote-exec" {
    connection {
      type        = "ssh"
      user        = "azureuser"
      private_key = file("${path.module}/terraform_azure")
      host        = azurerm_public_ip.public_ip.ip_address
    }

    inline = [
      "sudo apt-get update",
      "sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common",
      "curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -",
      "sudo add-apt-repository \"deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable\"",
      "sudo apt-get update",
      "sudo apt-get install -y docker-ce",
      "sudo usermod -aG docker azureuser",
      "sudo systemctl start docker",
      "sudo systemctl enable docker",
      "sudo docker run -d --name seq -e ACCEPT_EULA=Y -p 80:80 datalust/seq",
      "sudo docker run -d --name experiment-bj -p 5567:8080 oleksiikorniienko/experiment-bj"
    ]
  }
}

output "public_ip" {
  value = azurerm_public_ip.public_ip.ip_address
}
