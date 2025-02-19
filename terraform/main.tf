# Resource Group
resource "azurerm_resource_group" "sonarqube_rg" {
  name     = "rg-sonarqube-${var.environment}"
  location = var.location
  tags = {
    Environment = var.environment
  }
}

# Virtual Network
resource "azurerm_virtual_network" "sonarqube_vnet" {
  name                = "vnet-sonarqube-${var.environment}"
  address_space       = ["10.0.0.0/16"]
  location           = azurerm_resource_group.sonarqube_rg.location
  resource_group_name = azurerm_resource_group.sonarqube_rg.name
}

# Subnet
resource "azurerm_subnet" "sonarqube_subnet" {
  name                 = "subnet-sonarqube-${var.environment}"
  resource_group_name  = azurerm_resource_group.sonarqube_rg.name
  virtual_network_name = azurerm_virtual_network.sonarqube_vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_public_ip" "sonarqube_pip" {
  name                = "pip-sonarqube-${var.environment}"
  location           = azurerm_resource_group.sonarqube_rg.location
  resource_group_name = azurerm_resource_group.sonarqube_rg.name
  allocation_method   = "Static"  
  domain_name_label   = "sonarqube-${var.environment}"  
}

# Network Security Group
resource "azurerm_network_security_group" "sonarqube_nsg" {
  name                = "nsg-sonarqube-${var.environment}"
  location           = azurerm_resource_group.sonarqube_rg.location
  resource_group_name = azurerm_resource_group.sonarqube_rg.name

  security_rule {
    name                       = "SSH"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "HTTPS"
    priority                   = 1002
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "HTTP"
    priority                   = 1003
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

# Network Interface
resource "azurerm_network_interface" "sonarqube_nic" {
  name                = "nic-sonarqube-${var.environment}"
  location           = azurerm_resource_group.sonarqube_rg.location
  resource_group_name = azurerm_resource_group.sonarqube_rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.sonarqube_subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.sonarqube_pip.id
  }
}

# Connect NSG to NIC
resource "azurerm_network_interface_security_group_association" "sonarqube_nsg_assoc" {
  network_interface_id      = azurerm_network_interface.sonarqube_nic.id
  network_security_group_id = azurerm_network_security_group.sonarqube_nsg.id
}

# Virtual Machine
resource "azurerm_linux_virtual_machine" "sonarqube_vm" {
  name                = "vm-sonarqube-${var.environment}"
  resource_group_name = azurerm_resource_group.sonarqube_rg.name
  location           = azurerm_resource_group.sonarqube_rg.location
  size               = "Standard_B2s" 
  admin_username     = var.vm_username

  network_interface_ids = [
    azurerm_network_interface.sonarqube_nic.id
  ]

  admin_ssh_key {
    username   = var.vm_username
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb        = 30
  }

  source_image_reference {
    publisher = "askforcloudllc1651766049149"
    offer     = "sonarqube_on_ubuntu_22_4lts"
    sku       = "sonarqube_on_ubuntu_22_4lts"
    version   = "0.0.1"
  }
  }