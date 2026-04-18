import { Controller, Post, Body, UseGuards } from '@nestjs/common';
import { AuthService } from './auth.service';
import { RegisterDto } from './dto/register.dto';
import { AuthGuard } from '../../common/guards/auth/auth.guard';
import { User } from '../../common/decorators/user.decorator';

@Controller('auth')
export class AuthController {
  constructor(private readonly authService: AuthService) {}

  @Post('register')
  @UseGuards(AuthGuard)
  async register(
    @Body() registerDto: RegisterDto,
    @User() user: { uid: string; email: string },
  ) {
    return this.authService.register(user, registerDto);
  }
}
