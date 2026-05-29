# JuiceFS on WSL2 with TiKV + Ceph RGW

本目录是 JuiceFS 在 WSL2 环境的集成测试，依赖以下两个部署仓：

| 组件 | 用途 | 仓库 |
|------|------|------|
| **tikv-qemu** | TiKV 元数据引擎（3 节点） | [njutli/tikv-qemu](https://github.com/njutli/tikv-qemu) |
| **ceph-rgw-qemu** | Ceph RGW 对象存储（EC 4+2） | [njutli/ceph-rgw-qemu](https://github.com/njutli/ceph-rgw-qemu) |

## 架构

```
JuiceFS Client (宿主机 WSL2)
  │
  ├─ Metadata (TiKV):  tikv://172.16.0.101:2379,172.16.0.102:2379,172.16.0.103:2379/juicefs-test
  │     └─ 3 个 PD 节点 + 3 个 TiKV 节点 (tikv-qemu)
  │
  └─ Data (Ceph RGW):  --storage s3 --bucket http://172.16.1.101:80/juicefs-test
        └─ Ceph RGW S3 兼容 API (ceph-rgw-qemu)
```

## 前置条件

1. **tikv-qemu** 已部署，TiKV 集群运行中
2. **ceph-rgw-qemu** 已部署，Ceph RGW 运行中
3. JuiceFS 客户端已安装（`juicefs` 命令可用）

## 测试

```bash
bash test-juicefs.sh
```

测试步骤：
1. 格式化 JuiceFS 文件系统（TiKV 元数据 + Ceph RGW 数据）
2. 挂载到 `/tmp/juicefs-mnt`
3. 写入文本文件和 10MB 随机文件
4. 读取验证
5. 创建子目录和嵌套文件
6. 查看文件系统统计信息
7. 卸载

## RGW 认证信息

测试脚本使用的 RGW 凭证由 `ceph-rgw-qemu/deploy-ceph.sh` 自动创建：

```bash
# 查看用户信息
ssh ubuntu@172.16.1.101 "sudo radosgw-admin user info --uid=juicefs"
```

## 手动挂载

```bash
juicefs mount "tikv://172.16.0.101:2379,172.16.0.102:2379,172.16.0.103:2379/juicefs-test" /mnt/juicefs
```
