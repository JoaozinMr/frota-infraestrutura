variable "subscription_id" {
  description = "ID da assinatura Azure (az account show --query id -o tsv)."
  type        = string
}

variable "location" {
  description = "Região Azure."
  type        = string
  default     = "brazilsouth"
}

variable "prefixo" {
  description = "Prefixo dos nomes dos recursos."
  type        = string
  default     = "frota"
}

variable "dns_label" {
  description = "Rótulo DNS do IP público (<label>.<região>.cloudapp.azure.com). Deve ser único na região; null desativa."
  type        = string
  default     = null
}

variable "vm_size" {
  description = "Tamanho da VM."
  type        = string
  default     = "Standard_B2s"
}

variable "disco_gb" {
  description = "Tamanho do disco do SO (imagens .NET + dados do Redpanda/PostgreSQL)."
  type        = number
  default     = 64
}

variable "admin_username" {
  description = "Usuário administrador (SSH)."
  type        = string
  default     = "azureuser"
}

variable "ssh_public_key_path" {
  description = "Chave pública SSH usada para acessar a VM."
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

variable "ssh_origem_permitida" {
  description = "CIDR autorizado no SSH (recomendado: seu IP, ex. 203.0.113.10/32)."
  type        = string
  default     = "*"
}

variable "infra_repo_url" {
  description = "Repositório de infraestrutura clonado pelo cloud-init."
  type        = string
  default     = "https://github.com/JoaozinMr/frota-infraestrutura.git"
}

variable "infra_repo_branch" {
  description = "Branch do repositório de infraestrutura."
  type        = string
  default     = "main"
}

variable "sim_num_veiculos" {
  description = "Caminhões simulados na VM."
  type        = number
  default     = 1000
}

variable "sim_intervalo_segundos" {
  description = "Período de envio de cada caminhão (B2s: 2 vCPU/4 GiB; aumente se a VM saturar)."
  type        = number
  default     = 2
}
