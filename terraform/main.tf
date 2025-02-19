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

# Public IP - zmodyfikowany dla darmowej domeny
resource "azurerm_public_ip" "sonarqube_pip" {
  name                = "pip-sonarqube-${var.environment}"
  location           = azurerm_resource_group.sonarqube_rg.location
  resource_group_name = azurerm_resource_group.sonarqube_rg.name
  allocation_method   = "Static"  # Zmienione na Static
  domain_name_label   = "sonarqube-${var.environment}"  # Dodana darmowa subdomena
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
    publisher = "Canonical"
    offer     = "UbuntuServer"
    sku       = "18.04-LTS"
    version   = "latest"
  }

  custom_data = base64encode(<<-EOF
              #!/bin/bash
             
              apt-get update
              apt-get install -y apt-transport-https ca-certificates curl software-properties-common openssl jq

              # Instalacja certbot
              apt-get install -y certbot

              # Instalacja Docker
              curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
              add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
              apt-get update
              apt-get install -y docker-ce docker-ce-cli containerd.io

              # Instalacja Docker Compose
              curl -L "https://github.com/docker/compose/releases/download/1.29.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
              chmod +x /usr/local/bin/docker-compose

              mkdir -p /opt/sonarqube/certs

              # Pobierz domenę z metadanych Azure
              METADATA_ENDPOINT="http://169.254.169.254/metadata/instance"
              PUBLIC_IP=$(curl -s -H Metadata:true --noproxy "*" "$METADATA_ENDPOINT/network/interface/0/ipConfiguration/0/publicIpAddress/ipAddress?api-version=2021-02-01&format=text")
              RESOURCE_GROUP=$(curl -s -H Metadata:true --noproxy "*" "$METADATA_ENDPOINT/compute/resourceGroupName?api-version=2021-02-01&format=text")
              SUBSCRIPTION_ID=$(curl -s -H Metadata:true --noproxy "*" "$METADATA_ENDPOINT/compute/subscriptionId?api-version=2021-02-01&format=text")

              # Pobierz FQDN dla public IP
              TOKEN=$(curl -s -H Metadata:true --noproxy "*" "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fmanagement.azure.com%2F" | jq -r '.access_token')
              PUBLIC_IP_NAME=$(curl -s -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -H "Accept: application/json" -H "Metadata: true" --noproxy "*" "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Network/publicIPAddresses?api-version=2021-02-01" | jq -r '.value[] | select(.properties.ipAddress=="'$PUBLIC_IP'") | .name')
              DOMAIN_NAME=$(curl -s -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -H "Accept: application/json" -H "Metadata: true" --noproxy "*" "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Network/publicIPAddresses/$PUBLIC_IP_NAME?api-version=2021-02-01" | jq -r '.properties.dnsSettings.fqdn')

              echo "Domena serwera: $DOMAIN_NAME"
              
              # Zatrzymaj istniejące serwisy, które mogą blokować port 80
              systemctl stop apache2 2>/dev/null || true
              systemctl stop nginx 2>/dev/null || true

              # Uzyskaj certyfikat Let's Encrypt
              certbot certonly --standalone \
                --non-interactive \
                --agree-tos \
                --email admin@example.com \
                --domain $DOMAIN_NAME \
                --preferred-challenges http

              # Kopiuj certyfikaty do katalogu SonarQube
              cp /etc/letsencrypt/live/$DOMAIN_NAME/fullchain.pem /opt/sonarqube/certs/server.crt
              cp /etc/letsencrypt/live/$DOMAIN_NAME/privkey.pem /opt/sonarqube/certs/server.key

              chmod 644 /opt/sonarqube/certs/server.crt
              chmod 600 /opt/sonarqube/certs/server.key

              # Konfiguruj automatyczne odnawianie certyfikatu
              echo "0 0 1 * * certbot renew --quiet && cp /etc/letsencrypt/live/$DOMAIN_NAME/fullchain.pem /opt/sonarqube/certs/server.crt && cp /etc/letsencrypt/live/$DOMAIN_NAME/privkey.pem /opt/sonarqube/certs/server.key && docker-compose -f /opt/sonarqube/docker-compose.yml restart nginx" | crontab -

              # Konfiguracja NGINX
              cat << 'NGINX_CONF' > /opt/sonarqube/nginx.conf
              events {
                  worker_connections 1024;
              }

              http {
                  upstream sonarqube {
                      server sonarqube:9000;
                  }

                  server {
                      listen 80;
                      server_name _;
                      
                      # Przekierowanie na HTTPS
                      location / {
                          return 301 https://$host$request_uri;
                      }
                      
                      # Obsługa wyzwania Let's Encrypt
                      location /.well-known/acme-challenge/ {
                          root /var/www/certbot;
                      }
                  }

                  server {
                      listen 443 ssl;
                      server_name _;

                      ssl_certificate /etc/nginx/certs/server.crt;
                      ssl_certificate_key /etc/nginx/certs/server.key;
                      ssl_protocols TLSv1.2 TLSv1.3;
                      ssl_prefer_server_ciphers on;
                      
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
                    - "80:80"
                    - "443:443"
                  volumes:
                    - ./nginx.conf:/etc/nginx/nginx.conf:ro
                    - ./certs:/etc/nginx/certs:ro
                    - /var/www/certbot:/var/www/certbot:ro
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

              # Utwórz katalog dla certbot
              mkdir -p /var/www/certbot
            
              # Konfiguracja systemu dla SonarQube
              sysctl -w vm.max_map_count=262144
              sysctl -w fs.file-max=65536
              ulimit -n 65536
              ulimit -u 4096

              echo "vm.max_map_count=262144" >> /etc/sysctl.conf
              echo "fs.file-max=65536" >> /etc/sysctl.conf

              # Uruchom SonarQube
              cd /opt/sonarqube
              docker-compose up -d
              EOF
  )
}

output "sonarqube_url" {
  value = "https://${azurerm_public_ip.sonarqube_pip.fqdn}"
  description = "URL do dostępu do SonarQube"
}

output "sonarqube_admin_credentials" {
  value = "Login: admin, Default Password: admin"
  description = "Domyślne dane logowania do SonarQube"
}

output "sonarqube_vm_username" {
  value = var.vm_username
  description = "Nazwa użytkownika do SSH"
}

output "sonarqube_domain" {
  value = azurerm_public_ip.sonarqube_pip.fqdn
  description = "Domena dostępu do SonarQube"
}