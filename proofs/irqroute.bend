import Base
import ../laws/irqroute.bend as L

def L.irqroute.to_vcpu():
  {==}

def L.irqroute.first_spi():
  {==}

def L.irqroute.host_event(intid, level):
  match level:
    case False{}:
      {==}
    case True{}:
      {==}

def L.irqroute.lowered(cpu, intid):
  {==}

def L.irqroute.ppi():
  {==}

def L.irqroute.last_ppi():
  {==}

def L.irqroute.reg_first():
  {==}

def L.irqroute.reg_51():
  {==}

def L.irqroute.reg_last():
  {==}

def L.irqroute.irouter():
  {==}
