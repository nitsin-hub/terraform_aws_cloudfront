provider "aws" {
	region = "ap-south-1"
    profile = "nitprofile"
}

// Create key-pairs
resource "tls_private_key" "pvt_key"{
  algorithm = "RSA"
}

resource "aws_key_pair" "key_pair"{
  key_name = "mywebkey"
  public_key = tls_private_key.pvt_key.public_key_openssh
}

// Create Security Group
resource "aws_security_group" "server-sg" {
  description = "Security group rules to access server"
  name = "webserver_security"

  ingress {
    description = "inbound rule to allow port 22 for SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "inbound rule to allow port 80 to access webserver"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "sg-webserver"
  }
}

// Launch an EC2-instance and install packages
resource "aws_instance" "web"{
  ami = "ami-0447a12f28fddb066"
  instance_type = "t2.micro"
  key_name = "mywebkey"
  security_groups = ["webserver_security"]
  tags = {
          Name = "webserver"
  }
  connection {
          type = "ssh"
          user = "ec2-user"
          private_key = tls_private_key.pvt_key.private_key_pem
          host = aws_instance.web.public_ip
  }
  provisioner "remote-exec"{
     inline = [
         "sudo yum install httpd php git -y",
         "sudo systemctl restart httpd",
         "sudo systemctl enable httpd"
         ]
  }
}

// Create an EBS volume and attach to EC2-instance
resource "aws_ebs_volume" "ebs"{
    availability_zone = aws_instance.web.availability_zone 
    size =  1
    encrypted = true
    tags = {
             Name = "web_vol"
    }
}

resource "aws_volume_attachment" "vol_att"{
   volume_id = aws_ebs_volume.ebs.id
   instance_id = aws_instance.web.id
   device_name = "/dev/sdf"
   force_detach = true
}

// Format and Mount
resource "null_resource" "null_remote"{
    depends_on = [
             aws_volume_attachment.vol_att
             ]

    connection {
          type = "ssh"
          user = "ec2-user"
          private_key = tls_private_key.pvt_key.private_key_pem
          host = aws_instance.web.public_ip
    }

    provisioner "remote-exec"{
       inline = [
         "sudo mkfs.ext4 /dev/xvdf",
         "sudo mount /dev/xvdf /var/www/html",
         "sudo rm -rf /var/www/html/*",
         "sudo git clone https://github.com/nitsin-hub/static_website_php.git /var/www/html"
       ]
    }
}


// Create an Origin Access Identity (OAI)
resource "aws_cloudfront_origin_access_identity" "origin_access_identity" {
  comment = "This OAI is created to allow access of cloufront to S3 bucket using bucket policy"
}

// Create a S3 bucket
resource "aws_s3_bucket" "mybucket"{
  bucket = "cf-terra-bucket"
  acl    = "private"
  tags = {
    Name = "My bucket"
  }
}

// Attach Policy to S3 bucket
data "aws_iam_policy_document" "s3_policy" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.mybucket.arn}/*"]

    principals {
      type        = "AWS"
      identifiers = [aws_cloudfront_origin_access_identity.origin_access_identity.iam_arn]
    }
  }
}

resource "aws_s3_bucket_policy" "bucket_policy"{
  bucket = aws_s3_bucket.mybucket.id
  policy = data.aws_iam_policy_document.s3_policy.json
}

locals {
  s3_origin_id = "S3-cf-terra-bucket"
}

// Upload Github repository content to bucket 
resource "null_resource" "null_local"{
    depends_on = [ 
            aws_s3_bucket.mybucket
    ]
                   
    provisioner "local-exec"{
        command =  "git clone https://github.com/nitsin-hub/static_website_php.git static_web"
    }
    provisioner "local-exec"{
        command =  "aws s3 sync static_web/images/ s3://cf-terra-bucket/images" 
    }
    provisioner "local-exec"{
        when = destroy
        command = "echo Y | rmdir /s static_web"
    }
    provisioner "local-exec"{
        when = destroy
        command = " aws s3 rm s3://cf-terra-bucket/images --recursive"
    }
}

// Create CloudFront Distribution
resource "aws_cloudfront_distribution" "s3_distribution" {
  origin {
    domain_name = aws_s3_bucket.mybucket.bucket_regional_domain_name
    origin_id   = local.s3_origin_id
    s3_origin_config {
      origin_access_identity = aws_cloudfront_origin_access_identity.origin_access_identity.cloudfront_access_identity_path
    }
  }

  enabled            = true
  is_ipv6_enabled    = true
  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = local.s3_origin_id
    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }
    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
  }
  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  } 
  tags = {
    Environment = "production"
  }
  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

// Save distribution URL and instance Public IP in files
resource "null_resource" "save_urls"{
  provisioner "local-exec"{
     command = "echo ${aws_cloudfront_distribution.s3_distribution.domain_name} > distribution_url.txt"
  }
  provisioner "local-exec"{
     command = "echo ${aws_instance.web.public_ip} > instance_ip.txt"
  }
}

// Update source code files inside Document-root of webserver
resource "null_resource" "remote_code_update"{
    depends_on = [
             aws_cloudfront_distribution.s3_distribution
             ]

    connection {
          type = "ssh"
          user = "ec2-user"
          private_key = tls_private_key.pvt_key.private_key_pem
          host = aws_instance.web.public_ip
          }


    provisioner "remote-exec"{
       inline = [
           "sudo sed -i -e 's/src=\"images/src=\"https:\\/\\/${aws_cloudfront_distribution.s3_distribution.domain_name}\\/images/g' /var/www/html/*.*",
         ]
    }
}

// Create Snapshot of EBS volume
resource "aws_ebs_snapshot" "snap_ebs" {
  volume_id = aws_ebs_volume.ebs.id
  tags = {
    Name = "ebs_snapshot"
  }
}
