import models
import criterions
from torch.utils import data
import torch
import torch.distributed as dist
from datasets import build_dataset
from tasks.utils import split_dataset

class BaseTask():
    def __init__(self, cfg):
        self.cfg = cfg

    def build_model(self, cfg):
        return models.build_model(cfg)

    def load_datasets(self, data_cfg, preprocessor_cfg):
        #create train/val/test dataset
        dataset = build_dataset(data_cfg, task_cfg=self.cfg, preprocessor_cfg=preprocessor_cfg)

        train_set, val_set, test_set = split_dataset(dataset, data_cfg)
        self.dataset = dataset
        self.train_set = train_set
        self.valid_set = val_set
        self.test_set = test_set

    def train_step(self, batch, model, criterion, optimizer, scheduler, device, grad_clip=None):
        loss, logging_out = criterion(model, batch, device)
        loss.backward(loss)
        if grad_clip:
            grad_norm = torch.nn.utils.clip_grad_norm_(model.parameters(), grad_clip)
        optimizer.step()
        optimizer.zero_grad()
        scheduler.step(loss)

        logging_out["grad_norm"] = grad_norm.item()

        if self.cfg.dist_gpu:
            logging_out = self.reduce_logging_metrics(logging_out)

        return logging_out

    def build_criterion(self, cfg):
        return criterions.build_criterion(cfg)

    def get_batch_iterator(self, dataset, batch_size, shuffle=True, **kwargs):
        return self.get_data_loader(dataset, batch_size=batch_size, shuffle=shuffle, **kwargs)

    def get_data_loader(self, dataset, **kwargs):

        if not self.cfg.dist_gpu:
            data_loader = data.DataLoader(dataset, **kwargs)
        else:
            sampler = data.distributed.DistributedSampler(dataset, shuffle=kwargs.pop('shuffle', True))
            data_loader = data.DataLoader(dataset, shuffle=False, sampler=sampler, **kwargs)

        return data_loader

    def get_valid_outs():
        raise NotImplementedError

    def save_model_weights(self, model, states, multi_gpu):
        #expects a new state with "models" key
        if multi_gpu:
            return model.module.save_model_weights(states)
        return model.save_model_weights(states)

    def load_model_weights(self, model, states, multi_gpu):
        if multi_gpu:
            model.module.load_weights(states)
        else:
            model.load_weights(states)

    def reduce_logging_metrics(self, logging_out):
        reduced_out = {}
        for k,v in logging_out.items():
            if k.endswith("loss") or k.endswith("l1") or k == "grad_norm":
                v = torch.tensor([v], device=torch.cuda.current_device())
                dist.all_reduce(v)

                if k == "grad_norm":
                    reduced_out[k] = v.item()
                else:
                    reduced_out[k] = v.item() / dist.get_world_size()

            else:  # do not gather images
                reduced_out[k] = v

        return reduced_out
