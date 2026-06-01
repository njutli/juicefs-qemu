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
  │     ├─ 3 个 PD 节点（Raft 选举，任一个故障不影响服务）
  │     └─ 3 个 TiKV 节点（数据三副本，任一个故障不丢数据）
  │
  └─ Data (Ceph RGW):  --storage s3 --bucket http://rgw.ceph.local:80/juicefs-test
        ├─ RGW 实例 1: 172.16.1.101:80
        ├─ RGW 实例 2: 172.16.1.102:80
        └─ HA 方式：Linux glibc resolver round-robin + AWS SDK 重试
           /etc/hosts:
             172.16.1.101 rgw.ceph.local
             172.16.1.102 rgw.ceph.local
```

### 高可用设计

| 组件 | 冗余方式 | 单节点故障影响 |
|------|---------|-------------|
| TiKV PD | 3 节点 Raft | 自动选举 Leader，服务不中断 |
| TiKV Store | 3 副本 Raft | Region 自动迁移到其他节点 |
| Ceph MON | 3 节点 | 多数派存活即正常 |
| Ceph OSD | EC 4+2（6 OSD） | 任意 2 个 OSD 故障不丢数据 |
| Ceph RGW | 2 实例 + resolver round-robin | 挂一个实例时 AWS SDK 自动重试另一个 |

> **RGW 不实现自动故障切换的原因**：S3 协议本身只接受单 endpoint URL。通过 `/etc/hosts`（或 DNS）配置多个 IP + AWS SDK 内置重试，即可在不引入 LB 组件的情况下实现切换。

## 前置条件

1. **tikv-qemu** 已部署，TiKV 集群运行中
2. **ceph-rgw-qemu** 已部署，Ceph RGW 运行中
3. JuiceFS 客户端已安装（`juicefs` 命令可用）

## 测试

```bash
bash test-juicefs.sh
```

测试步骤：
1. 配置 RGW HA（`/etc/hosts` 添加两个 RGW 节点）
2. 格式化 JuiceFS 文件系统（TiKV 元数据 + Ceph RGW 数据）
3. 挂载到 `/tmp/juicefs-mnt`
4. 写入文本文件和 10MB 随机文件
5. 读取验证
6. 创建子目录和嵌套文件
7. 查看文件系统统计信息
8. 卸载

## RGW 认证信息

测试脚本使用的 RGW 凭证由 `ceph-rgw-qemu/deploy-ceph.sh` 自动创建：

```bash
ssh ubuntu@172.16.1.101 "sudo radosgw-admin user info --uid=juicefs"
```

## 手动挂载

先配置 RGW HA：

```bash
echo "172.16.1.101 rgw.ceph.local" | sudo tee -a /etc/hosts
echo "172.16.1.102 rgw.ceph.local" | sudo tee -a /etc/hosts
```

然后挂载：

```bash
juicefs mount "tikv://172.16.0.101:2379,172.16.0.102:2379,172.16.0.103:2379/juicefs-test" /mnt/juicefs
```
