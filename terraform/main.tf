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
    publisher = "Canonical"
    offer     = "UbuntuServer"
    sku       = "18.04-LTS"
    version   = "latest"
  }

   custom_data = base64encode(<<-EOF
              #!/bin/bash
             
              apt-get update
              apt-get install -y apt-transport-https ca-certificates curl software-properties-common openssl

              #  Docker
              curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
              add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
              apt-get update
              apt-get install -y docker-ce docker-ce-cli containerd.io
              usermod -aG docker azureuser
              # Ensure docker socket has correct permissions
              chmod 666 /var/run/docker.sock
              systemctl restart docker
              #  Docker Compose
              curl -L "https://github.com/docker/compose/releases/download/1.29.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
              chmod +x /usr/local/bin/docker-compose

              mkdir -p /opt/sonarqube/certs

              # self-signed
              openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
                -keyout /opt/sonarqube/certs/server.key \
                -out /opt/sonarqube/certs/server.crt \
                -subj "/C=PL/ST=State/L=City/O=Organization/CN=sonarqube"

              chmod 644 /opt/sonarqube/certs/server.crt
              chmod 600 /opt/sonarqube/certs/server.key

              #  nginx.conf
              cat << 'NGINX_CONF' > /opt/sonarqube/nginx.conf
              events {
                  worker_connections 1024;
              }

              http {
                  upstream sonarqube {
                      server sonarqube:9000;
                  }

                  server {
                      listen 443 ssl;
                      server_name _;

                      ssl_certificate /etc/nginx/certs/server.crt;
                      ssl_certificate_key /etc/nginx/certs/server.key;

                      location / {
                          proxy_pass http://sonarqube;
                          proxy_set_header Host $host;
                          proxy_set_header X-Real-IP $remote_addr;
                          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                          proxy_set_header X-Forwarded-Proto $scheme;
                      }
                  }
              }
              NGINX_CONF

              #   docker-compose.yml
              cat << 'DOCKER_COMPOSE' > /opt/sonarqube/docker-compose.yml
              version: "3"
              services:
                sonarqube:
                  image: sonarqube:community
                  environment:
                    - SONAR_JDBC_URL=jdbc:postgresql://db:5432/sonar
                    - SONAR_JDBC_USERNAME=sonar
                    - SONAR_JDBC_PASSWORD=sonar
                  volumes:
                    - sonarqube_data:/opt/sonarqube/data
                    - sonarqube_extensions:/opt/sonarqube/extensions
                    - sonarqube_logs:/opt/sonarqube/logs
                  depends_on:
                    - db

                nginx:
                  image: nginx:latest
                  ports:
                    - "443:443"
                  volumes:
                    - ./nginx.conf:/etc/nginx/nginx.conf:ro
                    - ./certs:/etc/nginx/certs:ro
                  depends_on:
                    - sonarqube

                db:
                  image: postgres:12
                  environment:
                    - POSTGRES_USER=sonar
                    - POSTGRES_PASSWORD=sonar
                  volumes:
                    - postgresql:/var/lib/postgresql
                    - postgresql_data:/var/lib/postgresql/data

              volumes:
                sonarqube_data:
                sonarqube_extensions:
                sonarqube_logs:
                postgresql:
                postgresql_data:
              DOCKER_COMPOSE

            
              sysctl -w vm.max_map_count=262144
              sysctl -w fs.file-max=65536
              ulimit -n 65536
              ulimit -u 4096

              echo "vm.max_map_count=262144" >> /etc/sysctl.conf
              echo "fs.file-max=65536" >> /etc/sysctl.conf

              # run SonarQube
              cd /opt/sonarqube
              docker-compose up -d
              EOF
  )
}